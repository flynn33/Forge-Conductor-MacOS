import Foundation
import AppKit
import Darwin
import Synchronization
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
        let text = try Self.extractedText(document)
        for fragment in [
            "ASCII CONTROL", "Section", "Detail", "strong emphasis inline",
            "Literal parentheses (left right) and backslash \\ marker.",
            "let_value = (left)\\right", "ASCII-SENTINEL-025", "ASCII native PDF",
        ] {
            Self.assertContainsScalars(text, fragment: fragment)
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
        let text = try Self.extractedText(document)
        Self.assertContainsScalars(text, fragment: "• first item")
        Self.assertContainsScalars(text, fragment: "• second item")
        Self.assertContainsScalars(text, fragment: "BULLET-SENTINEL-025")
    }

    func testUnicodeBodyExtractsExactScalars() throws {
        let fragments = ["Latin café déjà vu", "Ελληνικά", "Русский", "日本語", "العربية"]
        let (document, _) = try writeAndOpen(
            "unicode-body.pdf",
            content: fragments.joined(separator: "\n") + "\nUNICODE-BODY-SENTINEL-025",
            title: "Unicode body control"
        )
        let text = try Self.extractedText(document)
        for fragment in fragments + ["UNICODE-BODY-SENTINEL-025"] {
            Self.assertContainsScalars(text, fragment: fragment)
        }
    }

    func testUnicodeTitleExtractsExactScalars() throws {
        let title = "Title café 日本語"
        let (document, metadata) = try writeAndOpen(
            "unicode-title.pdf", content: "UNICODE-TITLE-SENTINEL-025", title: title
        )
        let text = try Self.extractedText(document)
        Self.assertContainsScalars(text, fragment: title)
        Self.assertContainsScalars(text, fragment: "UNICODE-TITLE-SENTINEL-025")
        XCTAssertEqual(metadata["title"] as? String, title)
    }

    func testUTF8SourceExplicitDestinationPreservesUnicode() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
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
                let document = try Self.openPDF(destination, metadata: result.payload)
                let visualText = try Self.extractedText(document)
                for fragment in ["UTF8 SOURCE", "UTF8-SOURCE-SENTINEL-025", "Explicit UTF8 source"] {
                    Self.assertContainsScalars(visualText, fragment: fragment)
                }
                let pages = try XCTUnwrap(try NativePDFTextReader.pages(in: Data(contentsOf: destination)))
                let text = pages.joined()
                for fragment in ["UTF8 SOURCE", marker, "UTF8-SOURCE-SENTINEL-025", "Explicit UTF8 source"] {
                    Self.assertContainsScalars(text, fragment: fragment)
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
        XCTAssertEqual(Self.whitespaceNormalizedScalars(pages.joined()), Self.whitespaceNormalizedScalars(content))
    }

    func testDefaultToolTitlesAndDestinationsRemainAvailable() throws {
        try Self.withToolApp(root: temporaryRoot) { app, client, project in
            let extensionless = project.appendingPathComponent("default-write")
            let written = try app.tools.call(
                name: "pdf_write",
                arguments: ["path": extensionless.path, "content": "DEFAULT-WRITE-SENTINEL-025"],
                clientID: client
            )
            XCTAssertTrue(written.ok, "\(written.payload)")
            XCTAssertEqual(written.payload["title"] as? String, "default-write")
            let writtenDocument = try Self.openPDF(
                extensionless.appendingPathExtension("pdf"), metadata: written.payload
            )
            let writtenText = try Self.extractedText(writtenDocument)
            Self.assertContainsScalars(writtenText, fragment: "default-write")
            Self.assertContainsScalars(writtenText, fragment: "DEFAULT-WRITE-SENTINEL-025")

            let source = project.appendingPathComponent("default-source.md")
            try Data("DEFAULT-SOURCE-SENTINEL-025\n".utf8).write(to: source)
            let converted = try app.tools.call(
                name: "pdf_from_file", arguments: ["source_path": source.path], clientID: client
            )
            XCTAssertTrue(converted.ok, "\(converted.payload)")
            XCTAssertEqual(converted.payload["source_path"] as? String, source.path)
            XCTAssertEqual(converted.payload["title"] as? String, "default-source")
            let convertedDocument = try Self.openPDF(
                project.appendingPathComponent("default-source.pdf"), metadata: converted.payload
            )
            let convertedText = try Self.extractedText(convertedDocument)
            Self.assertContainsScalars(convertedText, fragment: "default-source")
            Self.assertContainsScalars(convertedText, fragment: "DEFAULT-SOURCE-SENTINEL-025")
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
        Self.assertContainsScalars(first, fragment: "Paragraph 000 MULTIPAGE-SENTINEL-025")
        Self.assertContainsScalars(last, fragment: "Paragraph 129 MULTIPAGE-SENTINEL-025")
        let text = try Self.extractedText(document)
        for index in 0..<130 {
            Self.assertContainsScalars(text, fragment: String(format: "Paragraph %03d MULTIPAGE-SENTINEL-025", index))
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
        Self.assertContainsScalars(try Self.extractedText(document), fragment: marker)
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
        Self.assertContainsScalars(text, fragment: "X")
        for paragraph in paragraphs {
            Self.assertContainsScalars(text, fragment: paragraph)
        }
    }

    func testWideAndUnbrokenTextStaysWithinMediaBox() throws {
        let wide = String(repeating: "W", count: 86)
        let unbroken = String(repeating: "longword", count: 24)
        let (document, _) = try writeAndOpen(
            "wide-text.pdf", content: "GEOMETRY-SENTINEL-025\n\(wide)\n\(unbroken)",
            title: "Wide text geometry"
        )
        let text = try Self.extractedText(document)
        Self.assertContainsScalars(text, fragment: "GEOMETRY-SENTINEL-025")
        let compact = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        Self.assertContainsScalars(compact, fragment: wide)
        Self.assertContainsScalars(compact, fragment: unbroken)

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
        try Self.withToolApp(root: temporaryRoot) { app, client, project in
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
        return (try Self.openPDF(destination, metadata: metadata), metadata)
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

    private static func openPDF(_ url: URL, metadata: [String: Any]) throws -> PDFDocument {
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

    private static func extractedText(_ document: PDFDocument) throws -> String {
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

    private static func assertContainsScalars(
        _ text: String, fragment: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        // PDFKit may insert layout whitespace. Keep every non-whitespace scalar exact.
        let haystack = Self.whitespaceNormalizedScalars(text)
        let needle = Self.whitespaceNormalizedScalars(fragment)
        let found = !needle.isEmpty && haystack.count >= needle.count
            && (0...(haystack.count - needle.count)).contains { start in
                haystack[start..<(start + needle.count)].elementsEqual(needle)
            }
        XCTAssertTrue(found, "Missing scalar-exact fragment: \(fragment)", file: file, line: line)
    }

    private static func whitespaceNormalizedScalars(_ text: String) -> [UInt32] {
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

    private static func withToolApp(
        root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void
    ) throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
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

extension PDFWriterTests {
    func testDOCXNativeWorkerRoundTripPreservesExplicitParagraphBytes() async throws {
        try await Task.detached(priority: .utility) {
            XCTAssertFalse(Thread.isMainThread)
            let cases: [(String, String)] = [
                ("DOCX instruction", "DOCX instruction\n"), ("", "\n"),
                ("First paragraph.\nSecond paragraph.\n\nLast paragraph.\n", "First paragraph.\nSecond paragraph.\n\nLast paragraph.\n"),
                ("Latin e\u{0301} / é\n中文 日本語 한국어\nالعربية עברית Ελληνικά\n🙂 👩🏽‍💻\n", "Latin e\u{0301} / é\n中文 日本語 한국어\nالعربية עברית Ελληνικά\n🙂 👩🏽‍💻\n"),
                ("\tIndented\tcolumn\n\n  leading and trailing  \n", "\tIndented\tcolumn\n\n  leading and trailing  \n"),
                ("CRLF line\r\nCR line\rLF line\n", "CRLF line\nCR line\nLF line\n"),
                ("<>&\"' e\u{0301} 🙂\n", "<>&\"' e\u{0301} 🙂\n"),
                ("first\u{2029}second", "first\nsecond\n"),
                ("body\n\n\n", "body\n\n\n"), ("\n\n", "\n\n"),
                (String(repeating: "x", count: 65_536), String(repeating: "x", count: 65_536) + "\n"),
                (String(repeating: "文🙂e\u{0301}\n", count: 5_957) + String(repeating: "x", count: 9),
                 String(repeating: "文🙂e\u{0301}\n", count: 5_957) + String(repeating: "x", count: 9) + "\n"),
            ]
            for (source, expected) in cases {
                try autoreleasepool {
                    let data = try DOCXExportChildEntry.serialize(content: source)
                    XCTAssertTrue(data.starts(with: [0x50, 0x4b, 0x03, 0x04]))
                    XCTAssertGreaterThan(data.count, 0)
                    XCTAssertLessThanOrEqual(data.count, 1_048_576)
                    let imported = try NSAttributedString(data: data,
                        options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                        documentAttributes: nil)
                    XCTAssertEqual(Data(imported.string.utf8), Data(expected.utf8))
                    XCTAssertLessThanOrEqual(imported.string.utf8.count, 65_537)
                }
            }
        }.value
    }

    func testDOCXTextValidationKeepsLegalScalarsAndRejectsXMLControlsAndOversize() throws {
        XCTAssertEqual(try DOCXExportChildEntry.normalizedText("\t<>&\"' e\u{0301} 🙂\r\nCR\rP\u{2029}Q"),
                       "\t<>&\"' e\u{0301} 🙂\nCR\nP\nQ")
        XCTAssertEqual(try DOCXExportChildEntry.normalizedText(""), "")
        XCTAssertEqual(try DOCXExportChildEntry.normalizedText(String(repeating: "x", count: 65_536)).utf8.count, 65_536)
        for scalar in [UInt32(0), 1, 8, 11, 12, 31, 0xfffe, 0xffff] {
            let text = "left" + String(try XCTUnwrap(UnicodeScalar(scalar))) + "right"
            XCTAssertThrowsError(try DOCXExportChildEntry.normalizedText(text)) {
                XCTAssertEqual($0 as? NativeDOCXError, .invalidText)
            }
        }
        XCTAssertThrowsError(try DOCXExportChildEntry.normalizedText(String(repeating: "x", count: 65_537))) {
            XCTAssertEqual($0 as? NativeDOCXError, .contentTooLarge)
        }
        let unicode = String(repeating: "🙂", count: 16_384)
        XCTAssertEqual(try DOCXExportChildEntry.normalizedText(unicode), unicode)
        XCTAssertThrowsError(try DOCXExportChildEntry.normalizedText(unicode + "x")) {
            XCTAssertEqual($0 as? NativeDOCXError, .contentTooLarge)
        }
    }

    func testDOCXNativeOutputCapNeverReturnsPartialData() async throws {
        try await Task.detached(priority: .utility) {
            let complete = try DOCXExportChildEntry.serialize(content: "CAP café 日本語 🙂")
            XCTAssertGreaterThan(complete.count, 512)
            for cap in [512, 0, -1] {
                XCTAssertThrowsError(try DOCXExportChildEntry.serialize(content: "CAP café 日本語 🙂", maximumOutputBytes: cap)) {
                    XCTAssertEqual($0 as? NativeDOCXError, .outputTooLarge)
                }
            }
        }.value
    }

    @MainActor
    func testDOCXMainThreadCannotRunSerializerOrNativeTransport() async throws {
        XCTAssertTrue(Self.docxIsMainThread())
        XCTAssertThrowsError(try DOCXExportChildEntry.serialize(content: "main")) {
            XCTAssertEqual($0 as? NativeDOCXError, .workerRequired)
        }
        let fixture = DOCXTestTransport(output: Data([0x50, 0x4b, 0x03, 0x04]))
        let exporter = fixture.exporter()
        XCTAssertThrowsError(try exporter.encode("main", cancellation: nil)) {
            XCTAssertEqual($0 as? NativeDOCXError, .workerRequired)
        }
        XCTAssertEqual(fixture.runCount, 0)
        XCTAssertTrue(exporter.shutdown())
    }

    func testDOCXCompleteAdmittedTransportReturnsExactBinaryAndOriginalInput() async throws {
        try await Task.detached(priority: .utility) {
            let data = try Self.docxFixtureData()
            let fixture = DOCXTestTransport(output: data)
            let exporter = fixture.exporter()
            defer { XCTAssertTrue(exporter.shutdown()) }
            let control = ToolCallCancellation(timeoutSeconds: 10)
            let entered = DispatchTime.now().uptimeNanoseconds
            let content = "original\r\n日本語 🙂"
            let returned = try exporter.encode(content, cancellation: control)
            XCTAssertEqual(returned, data)
            XCTAssertEqual(fixture.input, Data(content.utf8))
            XCTAssertTrue(fixture.control === control)
            XCTAssertEqual(fixture.runCount, 1)
            XCTAssertEqual(fixture.recoveryCount, 0)
            let end = try XCTUnwrap(fixture.runDeadline)
            XCTAssertGreaterThan(end, entered)
            XCTAssertLessThanOrEqual(end - entered, 10_000_000_000)
        }.value
    }

    func testDOCXIncompleteTransportPreservesExistingFileAndMissingParent() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let valid = try Self.docxFixtureData()
                let existing = project.appendingPathComponent("keep.docx")
                let prior = Data("original destination".utf8)
                try prior.write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                let missing = project.appendingPathComponent("missing-parent", isDirectory: true)
                let modes: [DOCXTestTransport.Mode] = [.roleRejected, .auditUnavailable, .childInvalid,
                    .identityMismatch, .notAdmitted, .childExited, .exitFailure, .signalled,
                    .stdoutReadError, .stderrReadError, .stdoutForcedClose, .stderrForcedClose,
                    .stdoutTruncated, .stderrTruncated, .stdinPartial, .stdinOpen,
                    .termRequested, .killRequested, .emptyOutput, .badOutput, .oversizedOutput, .childOutputTooLarge,
                    .cancelled, .timedOut]
                for mode in modes {
                    for destination in [existing, missing.appendingPathComponent("new.docx")] {
                        let fixture = DOCXTestTransport(mode: mode, output: valid)
                        let exporter = fixture.exporter()
                        let control = ToolCallCancellation(timeoutSeconds: 10)
                        do {
                            let handled = try DocsToolPack(exporter: exporter).handle(name: "docx_write",
                                arguments: ["path": destination.path, "content": "transport sentinel"],
                                context: nil, clientID: client, app: app, cancellation: control)
                            let result = try XCTUnwrap(handled)
                            XCTAssertFalse(result.ok, "\(mode)")
                            XCTAssertEqual(result.payload["code"] as? String,
                                (mode == .oversizedOutput || mode == .childOutputTooLarge) ? "docx_output_too_large" : "docx_export_failed", "\(mode)")
                        } catch is CancellationError { XCTAssertEqual(mode, .cancelled) }
                        catch is ToolCallDeadlineExceeded { XCTAssertEqual(mode, .timedOut) }
                        XCTAssertEqual(fixture.runCount, 1)
                        XCTAssertTrue(exporter.shutdown(), "\(mode)")
                        XCTAssertEqual(fixture.recoveryCount, 0)
                        XCTAssertEqual(try Data(contentsOf: existing), prior)
                        XCTAssertEqual(try Self.docxMode(existing), 0o600)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
                    }
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).filter {
                    $0.hasPrefix(".forge-text-")
                }, [])
            }
        }.value
    }

    func testDOCXStrictTypesInputLimitsAndPreCancellationNeverReachTransport() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = project.appendingPathComponent("strict.docx")
                let prior = Data("preserve strict".utf8)
                try prior.write(to: file)
                let fixture = DOCXTestTransport(output: try Self.docxFixtureData())
                let exporter = fixture.exporter()
                defer { XCTAssertTrue(exporter.shutdown()) }
                let pack = DocsToolPack(exporter: exporter)
                let cases: [([String: Any], String)] = [
                    (["path": 7, "content": "text"], "invalid_path"),
                    (["path": true, "content": "text"], "invalid_path"),
                    (["path": "  \n", "content": "text"], "invalid_path"),
                    (["path": "nul\u{0}.docx", "content": "text"], "invalid_path"),
                    (["path": project.appendingPathComponent("no-extension").path, "content": "text"], "invalid_path"),
                    (["path": file.path, "content": 7], "missing_args"),
                    (["path": file.path, "content": false], "missing_args"),
                    (["path": file.path, "content": NSNull()], "missing_args"),
                    (["path": file.path, "content": String(repeating: "x", count: 65_537)], "content_too_large"),
                    (["path": file.path, "content": "illegal\u{1}"], "invalid_text"),
                ]
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try pack.handle(name: "docx_write", arguments: arguments,
                        context: nil, clientID: client, app: app, cancellation: ToolCallCancellation(timeoutSeconds: 10)))
                    XCTAssertFalse(result.ok)
                    XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 1)] {
                    if (control.remainingTimeInterval ?? 0) > 2.5 { control.cancel() }
                    XCTAssertThrowsError(try exporter.encode("valid", cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(fixture.runCount, 0)
                XCTAssertEqual(fixture.recoveryCount, 0)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).filter {
                    $0.hasPrefix(".forge-text-") || $0 == "no-extension" || $0 == "no-extension.docx"
                }, [])
            }
        }.value
    }

    func testDOCXToolAtomicReplacementPreservesModeAndBinaryReadback() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let data = try Self.docxFixtureData()
                let fixture = DOCXTestTransport(output: data)
                let exporter = fixture.exporter()
                defer { XCTAssertTrue(exporter.shutdown()) }
                let router = ToolRouter(app: app, packs: [DocsToolPack(exporter: exporter)])
                let existing = project.appendingPathComponent("replace.docx")
                try Data("replace me".utf8).write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.docx")] {
                    let result = try router.call(name: "docx_write", arguments: ["path": file.path, "content": "DOCX marker 日本語 🙂"], clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["format"] as? String, "docx")
                    XCTAssertEqual(result.payload["engine"] as? String, "appkit-office-open-xml")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, data.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(data))
                    XCTAssertEqual(result.payload["input_text_bytes"] as? Int, "DOCX marker 日本語 🙂".utf8.count)
                    XCTAssertEqual(result.payload["text_contract"] as? String, "docx-paragraphs-v1")
                    XCTAssertEqual(try Self.docxMode(file), file == existing ? 0o600 : 0o644)
                    XCTAssertEqual(try Data(contentsOf: file), data)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32_768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), data)
                }
                XCTAssertEqual(fixture.runCount, 2)
            }
        }.value
    }

    func testDOCXAuthorizedParentSwapNeverFollowsNewSymlink() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let parent = project.appendingPathComponent("branch", isDirectory: true)
                let moved = project.appendingPathComponent("original-branch", isDirectory: true)
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let original = Data("original inside".utf8), protected = Data("outside protected".utf8)
                try original.write(to: parent.appendingPathComponent("target.docx"))
                try protected.write(to: outside.appendingPathComponent("target.docx"))
                let data = try Self.docxFixtureData()
                let exporter = NativeDOCXExporter(run: { input, _, _ in
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                    return DOCXTestTransport.complete(input: input, output: data)
                }, recover: { _ in XCTFail("confirmed child must not need recovery"); return false })
                defer { XCTAssertTrue(exporter.shutdown()) }
                let router = ToolRouter(app: app, packs: [DocsToolPack(exporter: exporter)])
                let result = try router.call(name: "docx_write", arguments: ["path": parent.appendingPathComponent("target.docx").path, "content": "swap marker"], clientID: client)
                XCTAssertFalse(result.ok, "\(result.payload)")
                XCTAssertEqual(result.payload["code"] as? String, "docx_write_failed")
                XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("target.docx")), original)
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.docx")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["target.docx"])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.docx"])
            }
        }.value
    }

    func testDOCXFailedPinnedRenameCleansStagingAndPreservesDirectory() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("directory.docx", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let original = Data("directory survives failed rename".utf8)
                try original.write(to: destination.appendingPathComponent("keep"))
                let fixture = DOCXTestTransport(output: try Self.docxFixtureData())
                let exporter = fixture.exporter()
                defer { XCTAssertTrue(exporter.shutdown()) }
                let result = try XCTUnwrap(try DocsToolPack(exporter: exporter).handle(name: "docx_write",
                    arguments: ["path": destination.path, "content": "rename marker"], context: nil,
                    clientID: client, app: app, cancellation: ToolCallCancellation(timeoutSeconds: 10)))
                XCTAssertFalse(result.ok)
                XCTAssertEqual(result.payload["code"] as? String, "docx_write_failed")
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("keep")), original)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.docx"])
            }
        }.value
    }

    func testDOCXCancellationBeforePublicationPreservesExistingDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("cancel.docx")
                let prior = Data("existing cancellation sentinel".utf8)
                try prior.write(to: destination)
                let output = try Self.docxFixtureData()
                let control = ToolCallCancellation(timeoutSeconds: 10)
                let exporter = NativeDOCXExporter(run: { input, _, received in
                    XCTAssertTrue(received === control)
                    received.cancel()
                    return DOCXTestTransport.complete(input: input, output: output)
                }, recover: { _ in XCTFail("confirmed cancelled child must not need recovery"); return false })
                defer { XCTAssertTrue(exporter.shutdown()) }
                XCTAssertThrowsError(try DocsToolPack(exporter: exporter).handle(name: "docx_write",
                    arguments: ["path": destination.path, "content": "cancel marker"], context: nil,
                    clientID: client, app: app, cancellation: control)) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["cancel.docx"])
            }
        }.value
    }

    func testDOCXBusyAdmissionDoesNotQueueAndConfirmedCompletionReleasesSlot() async throws {
        let data = try await Task.detached(priority: .utility) { try Self.docxFixtureData() }.value
        let fixture = DOCXTestTransport(mode: .hold, output: data)
        let exporter = fixture.exporter()
        defer { fixture.release(); XCTAssertTrue(exporter.shutdown()) }
        let first = Task.detached(priority: .utility) { try exporter.encode("first", cancellation: ToolCallCancellation(timeoutSeconds: 10)) }
        try await Self.waitForDOCXRun(fixture)
        try await Task.detached(priority: .utility) {
            XCTAssertThrowsError(try exporter.encode("second", cancellation: ToolCallCancellation(timeoutSeconds: 10))) {
                XCTAssertEqual($0 as? NativeDOCXError, .busy)
            }
        }.value
        XCTAssertEqual(fixture.runCount, 1)
        fixture.setMode(.normal)
        fixture.release()
        let firstData = try await first.value
        XCTAssertEqual(firstData, data)
        let third = try await Task.detached(priority: .utility) { try exporter.encode("third", cancellation: nil) }.value
        XCTAssertEqual(third, data)
        XCTAssertEqual(fixture.runCount, 2)
    }

    func testDOCXShutdownCancelsExactActiveControlAndPermanentlyStopsAdmission() async throws {
        let data = try await Task.detached(priority: .utility) { try Self.docxFixtureData() }.value
        let fixture = DOCXTestTransport(mode: .untilCancelled, output: data)
        let exporter = fixture.exporter()
        let control = ToolCallCancellation(timeoutSeconds: 10)
        defer { control.cancel(); XCTAssertTrue(exporter.shutdown()) }
        let first = Task.detached(priority: .utility) { try exporter.encode("active", cancellation: control) }
        try await Self.waitForDOCXRun(fixture)
        let stopped = await Task.detached(priority: .utility) { exporter.shutdown() }.value
        XCTAssertTrue(stopped)
        do { _ = try await first.value; XCTFail("cancelled active export must not return bytes") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(control.isCancelled)
        XCTAssertTrue(fixture.observedCancellation)
        XCTAssertTrue(fixture.control === control)
        try await Task.detached(priority: .utility) {
            XCTAssertThrowsError(try exporter.encode("later", cancellation: nil)) {
                XCTAssertEqual($0 as? NativeDOCXError, .stopped)
            }
        }.value
        XCTAssertEqual(fixture.runCount, 1)
        XCTAssertTrue(exporter.shutdown())
    }

    func testDOCXUnconfirmedOwnersStayBusyUntilLaterExactDeadlineRecovery() async throws {
        try await Task.detached(priority: .utility) {
            let data = try Self.docxFixtureData()
            for mode in [DOCXTestTransport.Mode.throwUnconfirmed, .rawUnconfirmed] {
                let fixture = DOCXTestTransport(mode: mode, output: data)
                let exporter = fixture.exporter()
                XCTAssertThrowsError(try exporter.encode("unresolved", cancellation: ToolCallCancellation(timeoutSeconds: 10))) {
                    if mode == .throwUnconfirmed { XCTAssertTrue($0 is OwnedNativeTerminationUnconfirmed) }
                    else { XCTAssertEqual($0 as? NativeDOCXError, .unresolved) }
                }
                XCTAssertThrowsError(try exporter.encode("second", cancellation: nil)) {
                    XCTAssertEqual($0 as? NativeDOCXError, .busy)
                }
                XCTAssertEqual(fixture.runCount, 1)
                let originalEnd = try XCTUnwrap(fixture.runDeadline)
                XCTAssertFalse(exporter.shutdown())
                XCTAssertEqual(fixture.recoveryCount, 1)
                XCTAssertEqual(fixture.recoveryDeadline, originalEnd)
                fixture.setRecoveryConfirmed(true)
                XCTAssertTrue(exporter.shutdown())
                XCTAssertEqual(fixture.recoveryCount, 2)
                XCTAssertEqual(fixture.recoveryDeadline, originalEnd)
                XCTAssertTrue(exporter.shutdown())
                XCTAssertEqual(fixture.recoveryCount, 2)
                XCTAssertThrowsError(try exporter.encode("stopped", cancellation: nil)) {
                    XCTAssertEqual($0 as? NativeDOCXError, .stopped)
                }
                XCTAssertEqual(fixture.runCount, 1)
            }
        }.value
    }

    func testDOCXExpiredRecoveryStillPollsOriginalDeadlineWithoutFreshGrace() async throws {
        try await Task.detached(priority: .utility) {
            let fixture = DOCXTestTransport(mode: .delayedUnconfirmed, output: try Self.docxFixtureData())
            let exporter = fixture.exporter()
            XCTAssertThrowsError(try exporter.encode("expired", cancellation: ToolCallCancellation(timeoutSeconds: 2.6))) {
                XCTAssertEqual($0 as? NativeDOCXError, .unresolved)
            }
            let originalEnd = try XCTUnwrap(fixture.runDeadline)
            XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds, originalEnd)
            XCTAssertFalse(exporter.shutdown())
            fixture.setRecoveryConfirmed(true)
            XCTAssertTrue(exporter.shutdown())
            XCTAssertEqual(fixture.recoveryCount, 2)
            XCTAssertEqual(fixture.recoveryDeadline, originalEnd)
            XCTAssertEqual(fixture.runCount, 1)
        }.value
    }

    func testDOCXExplicitGrantDeniesWithoutTransportAndChangedBindingPreventsWrite() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("docx-denied-client")
                let owner = ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue)
                let reduced = ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                    allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                    maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes)
                _ = try app.projectContexts.bind(owner: owner, projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: reduced)
                let fixture = DOCXTestTransport(output: try Self.docxFixtureData())
                let exporter = fixture.exporter()
                defer { XCTAssertTrue(exporter.shutdown()) }
                let router = ToolRouter(app: app, packs: [DocsToolPack(exporter: exporter)])
                let destination = project.appendingPathComponent("grant.docx")
                let denied = try router.call(name: "docx_write", arguments: ["path": destination.path, "content": "grant"], clientID: deniedClient)
                XCTAssertFalse(denied.ok)
                XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(fixture.runCount, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                let data = try Self.docxFixtureData()
                let changing = NativeDOCXExporter(run: { input, _, _ in
                    _ = try app.projectContexts.beginReset(projectID: context.projectID,
                        expectedGeneration: context.projectGeneration)
                    _ = try app.projectContexts.completeReset(projectID: context.projectID,
                        expectedGeneration: context.projectGeneration)
                    return DOCXTestTransport.complete(input: input, output: data)
                }, recover: { _ in XCTFail("confirmed transport must not require recovery"); return false })
                defer { XCTAssertTrue(changing.shutdown()) }
                let currentRouter = ToolRouter(app: app, packs: [DocsToolPack(exporter: changing)])
                let stale = try currentRouter.call(name: "docx_write", arguments: ["path": destination.path, "content": "stale"], clientID: client)
                XCTAssertFalse(stale.ok)
                XCTAssertEqual(stale.payload["code"] as? String, "docx_export_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }.value
    }

    private static func docxIsMainThread() -> Bool { Thread.isMainThread }
    private static func docxFixtureData() throws -> Data {
        try DOCXExportChildEntry.serialize(content: "DOCX fixture café 日本語 🙂\n")
    }
    private static func docxMode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
    private static func waitForDOCXRun(_ fixture: DOCXTestTransport) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while fixture.runCount == 0, DispatchTime.now().uptimeNanoseconds < end {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard fixture.runCount == 1 else { throw DOCXTestFixtureError.waitExpired }
    }
}

private enum DOCXTestFixtureError: Error { case waitExpired }

private final class DOCXTestTransport: Sendable {
    enum Mode: Sendable, Equatable {
        case normal, hold, untilCancelled, throwUnconfirmed, rawUnconfirmed, delayedUnconfirmed
        case roleRejected, auditUnavailable, childInvalid, identityMismatch, notAdmitted, childExited
        case exitFailure, signalled, stdoutReadError, stderrReadError, stdoutForcedClose, stderrForcedClose
        case stdoutTruncated, stderrTruncated, stdinPartial, stdinOpen, termRequested, killRequested
        case emptyOutput, badOutput, oversizedOutput, childOutputTooLarge, cancelled, timedOut
    }
    private struct State: Sendable {
        var mode: Mode
        var runCount = 0
        var recoveryCount = 0
        var input: Data?
        var control: ToolCallCancellation?
        var runDeadline: UInt64?
        var recoveryDeadline: UInt64?
        var recoveryConfirmed = false
        var observedCancellation = false
    }
    private let state: Mutex<State>
    private let gate = DispatchSemaphore(value: 0)
    private let output: Data
    init(mode: Mode = .normal, output: Data) { state = Mutex(State(mode: mode)); self.output = output }
    var runCount: Int { state.withLock { $0.runCount } }
    var recoveryCount: Int { state.withLock { $0.recoveryCount } }
    var input: Data? { state.withLock { $0.input } }
    var control: ToolCallCancellation? { state.withLock { $0.control } }
    var runDeadline: UInt64? { state.withLock { $0.runDeadline } }
    var recoveryDeadline: UInt64? { state.withLock { $0.recoveryDeadline } }
    var observedCancellation: Bool { state.withLock { $0.observedCancellation } }
    func release() { gate.signal() }
    func setMode(_ value: Mode) { state.withLock { $0.mode = value } }
    func setRecoveryConfirmed(_ value: Bool) { state.withLock { $0.recoveryConfirmed = value } }
    func exporter() -> NativeDOCXExporter {
        NativeDOCXExporter(run: { [self] input, end, control in try run(input: input, end: end, control: control) },
                           recover: { [self] end in recover(end: end) })
    }
    static func complete(input: Data, output: Data) -> OwnedDuplexResult {
        OwnedDuplexResult(exitCode: 0, terminationSignal: nil,
            stdout: OwnedCapturedStream(data: output, end: .eof, truncated: false),
            stderr: OwnedCapturedStream(data: Data(), end: .eof, truncated: false),
            stdinBytesWritten: input.count, stdinClosed: true, admission: .admitted,
            timedOut: false, cancelled: false, termRequested: false, killRequested: false,
            terminationConfirmed: true)
    }
    private func run(input: Data, end: UInt64, control: ToolCallCancellation) throws -> OwnedDuplexResult {
        let mode = state.withLock { value in
            value.runCount += 1; value.input = input; value.control = control; value.runDeadline = end
            return value.mode
        }
        if mode == .hold, gate.wait(timeout: .now() + 3) != .success { throw DOCXTestFixtureError.waitExpired }
        if mode == .untilCancelled {
            let stop = min(end, DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            while !control.isCancelled, DispatchTime.now().uptimeNanoseconds < stop { Thread.sleep(forTimeInterval: 0.001) }
            state.withLock { $0.observedCancellation = control.isCancelled }
        }
        if mode == .delayedUnconfirmed {
            while DispatchTime.now().uptimeNanoseconds <= end { Thread.sleep(forTimeInterval: 0.001) }
        }
        if mode == .throwUnconfirmed {
            throw OwnedNativeTerminationUnconfirmed(processIdentifier: 123, signalError: nil, waitError: nil, killRequested: true)
        }
        let admission: OwnedAdmissionDisposition
        switch mode {
        case .roleRejected: admission = .roleRejected
        case .auditUnavailable: admission = .auditTokenUnavailable
        case .childInvalid: admission = .childInvalid
        case .identityMismatch: admission = .exactIdentityMismatch
        case .notAdmitted: admission = .notAttempted
        case .childExited: admission = .ownedChildExited
        default: admission = .admitted
        }
        let body: Data
        switch mode {
        case .emptyOutput, .childOutputTooLarge: body = Data()
        case .badOutput: body = Data("not a DOCX".utf8)
        case .oversizedOutput: body = Data(repeating: 0, count: 1_048_577)
        default: body = output
        }
        return OwnedDuplexResult(exitCode: mode == .childOutputTooLarge ? DOCXExportChildEntry.outputTooLargeExitCode : (mode == .exitFailure ? 1 : 0),
            terminationSignal: mode == .signalled ? 9 : nil,
            stdout: OwnedCapturedStream(data: body,
                end: mode == .stdoutReadError ? .readError(5) : (mode == .stdoutForcedClose ? .forcedClose : .eof),
                truncated: mode == .stdoutTruncated),
            stderr: OwnedCapturedStream(data: Data(),
                end: mode == .stderrReadError ? .readError(5) : (mode == .stderrForcedClose ? .forcedClose : .eof),
                truncated: mode == .stderrTruncated),
            stdinBytesWritten: mode == .stdinPartial ? max(0, input.count - 1) : input.count,
            stdinClosed: mode != .stdinOpen, admission: admission, timedOut: mode == .timedOut,
            cancelled: mode == .cancelled || (mode == .untilCancelled && control.isCancelled),
            termRequested: mode == .termRequested, killRequested: mode == .killRequested,
            terminationConfirmed: mode != .rawUnconfirmed && mode != .delayedUnconfirmed)
    }
    private func recover(end: UInt64) -> Bool {
        state.withLock { value in
            value.recoveryCount += 1; value.recoveryDeadline = end
            return value.recoveryConfirmed
        }
    }
}

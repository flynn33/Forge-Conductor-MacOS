import Darwin
import Foundation
import XCTest
@testable import ForgeConductorCore

final class NativePDFTextReaderTests: XCTestCase {
    func testCompleteTaggedPagesPreserveExactUnicodeAndLogicalOrder() async throws {
        for selected in [TaggedPDFFixtures.Case.completeUnicode, .completeUnicodeScalars,
                         .completeTwoLeaves, .completeTwoPages, .completeReverseMap] {
            let fixture = try TaggedPDFFixtures.make(selected)
            XCTAssertLessThanOrEqual(fixture.data.count, 64 * 1_024)
            let expected = try XCTUnwrap(fixture.expectedLogicalPages)
            try assertExactPages(try await read(fixture.data), expected: expected, detail: fixture.name)
        }
    }

    func testAllFourCoveredTextShowOperatorsRemainSupported() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeAllShowOperators)
        try assertExactPages(try await read(fixture.data),
            expected: try XCTUnwrap(fixture.expectedLogicalPages), detail: fixture.name)
    }

    func testChildActualTextIsValidatedWithoutDuplicatingOuterReplacement() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeNestedActualTextOnly)
        try assertExactPages(try await read(fixture.data),
            expected: try XCTUnwrap(fixture.expectedLogicalPages), detail: fixture.name)
    }

    func testMainThreadDeclinesBeforeParsingWhileUtilityWorkerReadsSameBytes() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        let mainResult = try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            return try NativePDFTextReader.pages(in: fixture.data)
        }
        XCTAssertNil(mainResult)
        try assertExactPages(try await read(fixture.data),
            expected: try XCTUnwrap(fixture.expectedLogicalPages), detail: fixture.name)
    }

    func testIncompleteMalformedAndUnsupportedTagsFallBackAsWholeDocument() async throws {
        for selected in TaggedPDFFixtures.Case.allCases {
            let fixture = try TaggedPDFFixtures.make(selected)
            XCTAssertLessThanOrEqual(fixture.data.count, 64 * 1_024)
            guard fixture.expectedLogicalPages == nil else { continue }
            let result = try await read(fixture.data)
            XCTAssertNil(result, "Returned partial or unsupported tagged text: \(fixture.name)")
        }
    }

    func testPartialAndUncoveredPolicyInputRetainsCompletePDFKitFallbackProvenance() async throws {
        let controls: [(TaggedPDFFixtures.Case, [String])] = [
            (.partialSecondLeaf, ["First visual run.", "Second visual run."]),
            (.uncoveredText, ["Visible fallback line.", "Additional uncovered instruction."]),
            (.partialSecondPage, ["Visible fallback line.", "Second page."]),
            (.uncoveredSecondPage, ["Visible fallback line.", "Uncovered second page."]),
        ]
        for (selected, fragments) in controls {
            let fixture = try TaggedPDFFixtures.make(selected)
            let result = await Task.detached(priority: .utility) {
                StjornarvaldNativePolicyExtractor.extract(
                    url: URL(fileURLWithPath: "/fixture-\(fixture.name).pdf"),
                    mode: mode_t(S_IFREG), data: fixture.data
                )
            }.value
            XCTAssertEqual(result.kind, .pdf)
            XCTAssertEqual(result.state, .indexed)
            XCTAssertFalse(result.segments.isEmpty)
            XCTAssertEqual(Set(result.segments.map(\.method)), ["pdfkit-text"])
            XCTAssertEqual(Set(result.segments.map(\.version)), ["1"])
            let text = result.segments.map(\.content).joined()
            XCTAssertLessThanOrEqual(text.utf8.count, 128 * 1_024)
            for fragment in fragments {
                XCTAssertTrue(text.contains(fragment), "Fallback lost \(fragment): \(fixture.name)")
            }
        }
    }

    func testWhitespaceSemanticPagesRetainPDFKitPolicyFallbackProvenance() async throws {
        let fixture = try TaggedPDFFixtures.make(.whitespaceActualText)
        try assertExactPages(try await read(fixture.data), expected: ["   "], detail: fixture.name)
        let result = await Task.detached(priority: .utility) {
            StjornarvaldNativePolicyExtractor.extract(
                url: URL(fileURLWithPath: "/fixture-\(fixture.name).pdf"),
                mode: mode_t(S_IFREG), data: fixture.data
            )
        }.value
        XCTAssertEqual(result.kind, .pdf)
        XCTAssertEqual(result.state, .indexed)
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertEqual(Set(result.segments.map(\.method)), ["pdfkit-text"])
        XCTAssertEqual(Set(result.segments.map(\.version)), ["1"])
        let text = result.segments.map(\.content).joined()
        XCTAssertLessThanOrEqual(text.utf8.count, 128 * 1_024)
        XCTAssertTrue(text.contains("Visible fallback line."))
    }

    func testInputPageAndElementQuotaBoundariesDeclineWithoutPartialPages() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        let expected = try XCTUnwrap(fixture.expectedLogicalPages)
        var limits = NativePDFTextReader.Limits()
        limits.maximumInputBytes = fixture.data.count
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumInputBytes -= 1
        try await assertDeclines(fixture.data, limits: limits)

        limits = .init()
        limits.maximumElements = 3 // Root, Document, one Span.
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumElements = 2
        try await assertDeclines(fixture.data, limits: limits)

        let twoPages = try TaggedPDFFixtures.make(.completeTwoPages)
        limits = .init()
        limits.maximumPages = 2
        try assertExactPages(try await read(twoPages.data, limits: limits),
            expected: try XCTUnwrap(twoPages.expectedLogicalPages))
        limits.maximumPages = 1
        try await assertDeclines(twoPages.data, limits: limits)
    }

    func testStringQuotaBoundariesPreserveScalarsAndRejectOneByteLess() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        let expected = try XCTUnwrap(fixture.expectedLogicalPages)
        let text = try XCTUnwrap(expected.first)
        let encodedBytes = 2 + text.utf16.count * 2
        let decodedBytes = text.utf8.count

        var limits = NativePDFTextReader.Limits()
        limits.maximumEncodedStringBytes = encodedBytes
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumEncodedStringBytes -= 1
        try await assertDeclines(fixture.data, limits: limits)

        limits = .init()
        limits.maximumDecodedStringBytes = decodedBytes
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumDecodedStringBytes -= 1
        try await assertDeclines(fixture.data, limits: limits)

        limits = .init()
        limits.maximumTotalTextBytes = decodedBytes
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumTotalTextBytes -= 1
        try await assertDeclines(fixture.data, limits: limits)
    }

    func testCumulativeDecodeQuotaIncludesSuppressedChildActualText() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeNestedActualTextOnly)
        let expected = try XCTUnwrap(fixture.expectedLogicalPages)
        let outerBytes = expected.reduce(0) { $0 + $1.utf8.count }
        let childBytes = "日".utf8.count
        var limits = NativePDFTextReader.Limits()
        limits.maximumTotalTextBytes = outerBytes + childBytes
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumTotalTextBytes -= 1
        XCTAssertGreaterThanOrEqual(limits.maximumTotalTextBytes, outerBytes)
        try await assertDeclines(fixture.data, limits: limits)
    }

    func testOperatorAndCumulativeArrayQuotaBoundariesAreFinite() async throws {
        let fixture = try TaggedPDFFixtures.make(.quotaProbe, repeatedShows: 64)
        let expected = try XCTUnwrap(fixture.expectedLogicalPages)
        var limits = NativePDFTextReader.Limits()
        // BDC, BT, Tf, Tm,64 Tj, ET, EMC.
        limits.maximumOperators = 70
        try assertExactPages(try await read(fixture.data, limits: limits), expected: expected)
        limits.maximumOperators = 69
        try await assertDeclines(fixture.data, limits: limits)

        let allShows = try TaggedPDFFixtures.make(.completeAllShowOperators)
        limits = .init()
        // One structural child,2 Tf operands,6 Tm operands,3 TJ entries.
        limits.maximumArrayItems = 12
        try assertExactPages(try await read(allShows.data, limits: limits),
            expected: try XCTUnwrap(allShows.expectedLogicalPages))
        limits.maximumArrayItems = 11
        try await assertDeclines(allShows.data, limits: limits)
    }

    func testInvalidLimitsDeclineWithoutThrowing() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        var controls: [NativePDFTextReader.Limits] = []
        var limits = NativePDFTextReader.Limits()
        limits.maximumInputBytes = -1; controls.append(limits)
        limits = .init(); limits.maximumPages = 0; controls.append(limits)
        limits = .init(); limits.maximumElements = -1; controls.append(limits)
        limits = .init(); limits.maximumEncodedStringBytes = -1; controls.append(limits)
        limits = .init(); limits.maximumDecodedStringBytes = -1; controls.append(limits)
        limits = .init(); limits.maximumTotalTextBytes = -1; controls.append(limits)
        limits = .init(); limits.maximumOperators = -1; controls.append(limits)
        limits = .init(); limits.maximumArrayItems = -1; controls.append(limits)
        for control in controls { try await assertDeclines(fixture.data, limits: control) }
    }

    func testCancellationAfterFirstScanOperatorPropagatesAndNextReadSucceeds() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        let observedChecks = try await Task.detached(priority: .utility) {
            var checks = 0
            do {
                _ = try NativePDFTextReader.pages(in: fixture.data, cancellationCheck: {
                    checks += 1
                    // Six admission checks, then the first BDC scan check; cancel at BT.
                    if checks == 8 { throw CancellationError() }
                })
                throw ProbeError.cancellationWasSwallowed
            } catch is CancellationError {
                return checks
            }
        }.value
        XCTAssertEqual(observedChecks, 8)
        try assertExactPages(try await read(fixture.data),
            expected: try XCTUnwrap(fixture.expectedLogicalPages))
    }

    func testArbitraryCancellationCallbackErrorIsPreserved() async throws {
        let fixture = try TaggedPDFFixtures.make(.completeUnicode)
        let observedChecks = try await Task.detached(priority: .utility) {
            var checks = 0
            do {
                _ = try NativePDFTextReader.pages(in: fixture.data, cancellationCheck: {
                    checks += 1
                    if checks == 8 { throw ProbeError.callbackSentinel }
                })
                throw ProbeError.cancellationWasSwallowed
            } catch ProbeError.callbackSentinel {
                return checks
            }
        }.value
        XCTAssertEqual(observedChecks, 8)
    }

    private enum ProbeError: Error { case callbackSentinel, cancellationWasSwallowed }

    private func read(_ data: Data, limits: NativePDFTextReader.Limits = .init()) async throws -> [String]? {
        try await Task.detached(priority: .utility) {
            try NativePDFTextReader.pages(in: data, limits: limits)
        }.value
    }

    private func assertDeclines(
        _ data: Data, limits: NativePDFTextReader.Limits,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let result = try await read(data, limits: limits)
        XCTAssertNil(result, file: file, line: line)
    }

    private func assertExactPages(
        _ actual: [String]?, expected: [String], detail: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let pages = try XCTUnwrap(actual, "Expected complete tagged pages: \(detail)", file: file, line: line)
        XCTAssertEqual(pages.count, expected.count, detail, file: file, line: line)
        for (page, reference) in zip(pages, expected) {
            XCTAssertEqual(page.unicodeScalars.map(\.value), reference.unicodeScalars.map(\.value),
                "Scalar order changed: \(detail)", file: file, line: line)
        }
    }
}

// Raw fixtures exercise semantic ownership and fallback, not native glyph appearance.
// No fixture performs file writes; each finite object/xref buffer is capped at64KiB.
private enum TaggedPDFFixtures {
    static let maximumFixtureBytes = 64 * 1_024
    static let maximumObjectBytes = 32 * 1_024
    static let maximumActualTextBytes = 4 * 1_024
    static let maximumObjects = 16
    static let mixed = "café Ελληνικά Русский 日本語 العربية"
    static let punctuation = "Latin العربية. 123 (45), source."
    static let identifier = "abcאבג 6789; MIXED-ID-025."

    enum Case: String, CaseIterable, Sendable {
        case completeUnicode, completeTwoLeaves, completeTwoPages, completeUnicodeScalars
        case completeAllShowOperators, completeNestedActualTextOnly, completeReverseMap, whitespaceActualText
        case untagged, missingActualText, partialSecondLeaf, partialSecondPage, uncoveredText, uncoveredSecondPage
        case wrongPage, duplicateTreeMCID, duplicateStreamMCID
        case orphanStreamMCID, orphanTreeMCID, wrongReverseMap, missingReverseMap
        case wrongParent, nestedTag, nestedMCID, childActualTextWithoutOwner, formXObject, namedProperty
        case arrayMCID, fractionalTreeMCID, indirectLeafCycle
        case missingBDCOperand, wrongBDCOperand, extraBDCOperand, missingEMC, extraEMC
        case wrongTjOperand, extraTjOperand, wrongTJElement, wrongQuoteOperand, wrongDoubleQuoteOperand
        case negativeMCID, nonIntegerMCID, invalidUTF16, bomOnlyActualText
        case danglingStructParents, danglingReverseKids, danglingReverseLimits, pageAnnotations, catalogAcroForm, emptyStructure, structureCycle, parentTreeCycle
        case quotaProbe
    }

    struct Fixture: Sendable {
        let name: String
        let data: Data
        // Negatives must fall back as a whole, never return a tagged prefix.
        // Per-page leaves concatenate verbatim; no separator is inserted by the reader.
        let expectedLogicalPages: [String]?
    }

    enum BuildError: Error { case invalidCount, excessiveString, nonASCIIObject, excessiveObject, excessivePDF }

    static func make(_ selected: Case, repeatedShows: Int = 64) throws -> Fixture {
        guard (1...64).contains(repeatedShows) else { throw BuildError.invalidCount }
        let actual = [mixed, punctuation, identifier].joined(separator: "\n")
        let actualHex = try utf16Hex(actual)
        let firstHex = try utf16Hex(mixed)
        let secondHex = try utf16Hex(punctuation)
        var objects = [String](repeating: "null", count: maximumObjects)
        func set(_ number: Int, _ body: String) { objects[number - 1] = body }
        set(1, "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot 6 0 R >>")
        set(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        set(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        set(6, "<< /Type /StructTreeRoot /K 7 0 R >>")
        set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R] >>")
        set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText \(actualHex) >>")
        let begin = "BT /F1 11 Tf 1 0 0 1 50 700 Tm "
        let end = " ET\n"
        func marked(_ mcid: String, _ shows: String = "(Visible fallback line.) Tj", y: Int = 700) -> String {
            let textBegin = "BT /F1 11 Tf 1 0 0 1 50 \(y) Tm "
            return "/P << /MCID \(mcid) >> BDC \(textBegin)\(shows)\(end)EMC\n"
        }
        func stream(_ content: String, extra: String = "") -> String {
            "<< /Length \(content.utf8.count) \(extra)>>\nstream\n\(content)endstream"
        }
        var content = marked("1")
        var expected: [String]? = [actual]

        switch selected {
        case .completeUnicode: break
        case .completeUnicodeScalars:
            let scalars = "e\u{301} \u{1F642} cafe\u{301} אבג 123."
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText \(try utf16Hex(scalars)) >>")
            expected = [scalars]
        case .completeTwoLeaves, .partialSecondLeaf, .duplicateTreeMCID:
            set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R 10 0 R] >>")
            let firstParagraphHex = try utf16Hex(mixed + "\n")
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText \(firstParagraphHex) >>")
            let secondMCID = selected == .duplicateTreeMCID ? 1 : 2
            let replacement = selected == .partialSecondLeaf ? "" : "/ActualText \(secondHex)"
            set(10, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K \(secondMCID) \(replacement) >>")
            // Physical order deliberately differs from the tree's logical order.
            content = selected == .duplicateTreeMCID ? marked("1")
                : marked("2", "(Second visual run.) Tj", y: 680) + marked("1", "(First visual run.) Tj")
            expected = selected == .completeTwoLeaves ? [mixed + "\n" + punctuation] : nil
        case .completeTwoPages, .wrongPage, .partialSecondPage, .uncoveredSecondPage:
            set(2, "<< /Type /Pages /Kids [3 0 R 12 0 R] /Count 2 >>")
            set(12, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 13 0 R >>")
            let secondPageContent = selected == .uncoveredSecondPage
                ? begin + "(Uncovered second page.) Tj" + end
                : marked("1", "(Second page.) Tj")
            set(13, stream(secondPageContent))
            set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R 14 0 R] >>")
            let firstPage = selected == .wrongPage ? 12 : 3
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg \(firstPage) 0 R /K 1 /ActualText \(firstHex) >>")
            let replacement = selected == .partialSecondPage ? "" : "/ActualText \(secondHex)"
            set(14, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 12 0 R /K 1 \(replacement) >>")
            expected = selected == .completeTwoPages ? [mixed, punctuation] : nil
        case .completeAllShowOperators:
            content = marked("1", "(A) Tj [(B) -120 (C)] TJ (D) ' 0 0 (E) \"")
        case .completeNestedActualTextOnly:
            let childHex = try utf16Hex("日")
            content = "/P << /MCID 1 >> BDC " + begin + "(First run.) Tj "
                + "/Span << /ActualText \(childHex) >> BDC (Child run.) Tj EMC "
                + "(Last run.) Tj" + end + "EMC\n"
        case .completeReverseMap:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /StructParents 0 >>")
            set(6, "<< /Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>")
            set(9, "<< /Nums [0 [null 8 0 R]] >>")
        case .whitespaceActualText:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText <FEFF002000200020> >>")
            expected = ["   "]
        case .untagged:
            set(1, "<< /Type /Catalog /Pages 2 0 R >>")
            content = begin + "(Untagged fallback text.) Tj" + end
            expected = nil
        case .missingActualText:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 >>")
            expected = nil
        case .uncoveredText:
            content += "BT /F1 11 Tf 1 0 0 1 50 680 Tm (Additional uncovered instruction.) Tj" + end
            expected = nil
        case .duplicateStreamMCID:
            content += marked("1", "(Duplicate marked sequence.) Tj")
            expected = nil
        case .orphanStreamMCID:
            content += marked("2", "(Orphan marked sequence.) Tj")
            expected = nil
        case .orphanTreeMCID:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 2 /ActualText \(actualHex) >>")
            expected = nil
        case .wrongReverseMap:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /StructParents 0 >>")
            set(6, "<< /Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>")
            set(9, "<< /Nums [0 [null 7 0 R]] >>")
            expected = nil
        case .missingReverseMap:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /StructParents 0 >>")
            set(6, "<< /Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>")
            expected = nil
        case .wrongParent:
            set(8, "<< /Type /StructElem /S /Span /P 6 0 R /Pg 3 0 R /K 1 /ActualText \(actualHex) >>")
            expected = nil
        case .nestedTag:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K [15 0 R] /ActualText \(actualHex) >>")
            set(15, "<< /Type /StructElem /S /Span /P 8 0 R /Pg 3 0 R /K 1 /ActualText \(firstHex) >>")
            content = "/Span BMC\n" + marked("1") + "EMC\n"
            expected = nil
        case .nestedMCID:
            set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [8 0 R 10 0 R] >>")
            set(10, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 2 /ActualText \(secondHex) >>")
            content = "/P << /MCID 1 >> BDC " + begin + "(Outer owner.) Tj "
                + "/Span << /MCID 2 >> BDC (Nested owner.) Tj EMC" + end + "EMC\n"
            expected = nil
        case .childActualTextWithoutOwner:
            content += "/Span << /ActualText \(try utf16Hex("日")) >> BDC "
                + begin + "(Unowned replacement.) Tj" + end + "EMC\n"
            expected = nil
        case .formXObject:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Fm0 11 0 R >> >> /Contents 4 0 R >>")
            set(11, stream(begin + "(Form text.) Tj" + end,
                extra: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> "))
            content = "/Span << /MCID 1 >> BDC /Fm0 Do EMC\n"
            expected = nil
        case .namedProperty:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /Properties << /MC1 << /MCID 1 >> >> >> /Contents 4 0 R >>")
            content = "/Span /MC1 BDC " + begin + "(Named property.) Tj" + end + "EMC\n"
            expected = nil
        case .arrayMCID:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K [1] /ActualText \(actualHex) >>")
            expected = nil
        case .fractionalTreeMCID:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1.5 /ActualText \(actualHex) >>")
            expected = nil
        case .indirectLeafCycle:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 8 0 R /ActualText \(actualHex) >>")
            expected = nil
        case .missingBDCOperand:
            content = "/Span BDC " + begin + "(Missing dictionary.) Tj" + end + "EMC\n"
            expected = nil
        case .wrongBDCOperand:
            content = "/Span 1 BDC " + begin + "(Wrong dictionary type.) Tj" + end + "EMC\n"
            expected = nil
        case .extraBDCOperand:
            content = "1 /P << /MCID 1 >> BDC " + begin + "(Extra BDC operand.) Tj" + end + "EMC\n"
            expected = nil
        case .missingEMC:
            content = "/Span << /MCID 1 >> BDC " + begin + "(Open marked sequence.) Tj" + end
            expected = nil
        case .extraEMC:
            content += "EMC\n"
            expected = nil
        case .wrongTjOperand: content = marked("1", "123 Tj"); expected = nil
        case .extraTjOperand: content = marked("1", "(Extra) (Operand) Tj"); expected = nil
        case .wrongTJElement: content = marked("1", "[(A) /Bad] TJ"); expected = nil
        case .wrongQuoteOperand: content = marked("1", "123 '"); expected = nil
        case .wrongDoubleQuoteOperand: content = marked("1", "0 /Bad (E) \""); expected = nil
        case .negativeMCID: content = marked("-1"); expected = nil
        case .nonIntegerMCID: content = marked("1.5"); expected = nil
        case .invalidUTF16:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText <FEFFD800> >>")
            expected = nil
        case .bomOnlyActualText:
            set(8, "<< /Type /StructElem /S /Span /P 7 0 R /Pg 3 0 R /K 1 /ActualText <FEFF> >>")
            expected = nil
        case .danglingStructParents:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /StructParents 999 0 R >>")
            expected = nil
        case .danglingReverseKids, .danglingReverseLimits:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /StructParents 0 >>")
            set(6, "<< /Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>")
            let extra = selected == .danglingReverseKids ? "/Kids 999 0 R" : "/Limits 999 0 R"
            set(9, "<< /Nums [0 [null 8 0 R]] \(extra) >>")
            expected = nil
        case .pageAnnotations:
            set(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [15 0 R] >>")
            set(15, "<< /Type /Annot /Subtype /Text /Rect [50 50 80 80] /P 3 0 R /Contents (Annotation semantic instruction.) >>")
            expected = nil
        case .catalogAcroForm:
            set(1, "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot 6 0 R /AcroForm 16 0 R >>")
            set(15, "<< /FT /Tx /T (instruction-field) /V (Form semantic instruction.) >>")
            set(16, "<< /Fields [15 0 R] >>")
            expected = nil
        case .emptyStructure:
            set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [] >>")
            content = "0 0 10 10 re S\n"
            expected = nil
        case .structureCycle:
            set(7, "<< /Type /StructElem /S /Document /P 6 0 R /K [7 0 R] >>")
            expected = nil
        case .parentTreeCycle:
            set(6, "<< /Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R >>")
            set(9, "<< /Kids [9 0 R] /Limits [0 0] >>")
            expected = nil
        case .quotaProbe:
            let shows = (0..<repeatedShows).map { "(Quota \($0).) Tj" }.joined(separator: " ")
            content = marked("1", shows)
        }
        set(4, stream(content))
        return Fixture(name: selected.rawValue, data: try pdf(objects), expectedLogicalPages: expected)
    }

    private static func utf16Hex(_ text: String) throws -> String {
        guard text.utf8.count <= maximumActualTextBytes else { throw BuildError.excessiveString }
        var result = "<FEFF"
        for unit in text.utf16 { result += String(format: "%04X", unit) }
        result += ">"
        return result
    }

    private static func pdf(_ objects: [String]) throws -> Data {
        guard objects.count == maximumObjects else { throw BuildError.invalidCount }
        var result = Data("%PDF-1.7\n%finite-tagged-fixture\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            guard object.unicodeScalars.allSatisfy({ $0.value < 128 }) else { throw BuildError.nonASCIIObject }
            guard object.utf8.count <= maximumObjectBytes else { throw BuildError.excessiveObject }
            let body = Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
            guard body.count <= maximumFixtureBytes - result.count else { throw BuildError.excessivePDF }
            offsets.append(result.count)
            result.append(body)
        }
        let xrefOffset = result.count
        var trailer = "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        let tail = Data(trailer.utf8)
        guard tail.count <= maximumFixtureBytes - result.count else { throw BuildError.excessivePDF }
        result.append(tail)
        return result
    }
}

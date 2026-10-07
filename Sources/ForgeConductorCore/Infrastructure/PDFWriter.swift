// PDFWriter.swift
// What: Generates native PDF documents from the document tools' bounded text sources.
// How: CoreText lays out Unicode glyphs; CoreGraphics writes pages into a bounded
// consumer before the existing atomic destination write.
// Why: PDF text must remain readable and extractable, including native font fallback.

import Foundation
import CoreGraphics
import CoreText

public enum PDFWriter {
    private static let maximumOutputBytes = 64 * 1_024 * 1_024

    private enum WriterError: LocalizedError {
        case contextUnavailable
        case layoutUnavailable
        case outputTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .contextUnavailable: return "The native PDF context could not be created."
            case .layoutUnavailable: return "The text could not be laid out within the PDF page."
            case .outputTooLarge(let limit): return "PDF output is limited to \(limit) bytes."
            }
        }
    }

    private final class Output {
        var data = Data()
        var error: Error?
        let cancellationCheck: (() throws -> Void)?
        let maximumBytes: Int

        init(maximumBytes: Int, cancellationCheck: (() throws -> Void)?) {
            self.maximumBytes = maximumBytes
            self.cancellationCheck = cancellationCheck
        }

        func check() throws {
            if let error { throw error }
            do { try cancellationCheck?() }
            catch {
                self.error = error
                throw error
            }
        }

        func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
            do {
                try check()
                guard count <= maximumBytes - data.count else {
                    throw WriterError.outputTooLarge(maximumBytes)
                }
                data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
                return count
            } catch {
                self.error = error
                return 0
            }
        }
    }

    public static func write(
        path: URL,
        content: String,
        title: String = "",
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> [String: Any] {
        try write(path: path, content: content, title: title,
                  outputByteLimit: maximumOutputBytes, cancellationCheck: cancellationCheck)
    }

    // The internal lower limit exercises the real native consumer failure path.
    static func write(
        path: URL, content: String, title: String = "", outputByteLimit: Int,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> [String: Any] {
        let output = Output(maximumBytes: max(0, min(outputByteLimit, maximumOutputBytes)),
                            cancellationCheck: cancellationCheck)
        try output.check()
        let retainedOutput = Unmanaged.passRetained(output)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { information, bytes, count in
                guard let information else { return 0 }
                return Unmanaged<Output>.fromOpaque(information).takeUnretainedValue()
                    .append(bytes, count: count)
            },
            releaseConsumer: { information in
                if let information { Unmanaged<Output>.fromOpaque(information).release() }
            }
        )
        guard let consumer = CGDataConsumer(info: retainedOutput.toOpaque(), cbks: &callbacks) else {
            retainedOutput.release()
            throw WriterError.contextUnavailable
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw WriterError.contextUnavailable
        }
        var pageOpen = false
        var closed = false
        defer {
            if !closed {
                if pageOpen { context.endPDFPage() }
                context.closePDF()
            }
        }

        let margin: CGFloat = 50
        let width = Double(mediaBox.width - 2 * margin)
        let top: CGFloat = mediaBox.height - 50
        let bottom: CGFloat = 50
        let sizes: [CGFloat] = [8, 9, 11, 12, 13, 16, 18]
        let fonts = Dictionary(uniqueKeysWithValues: sizes.map {
            ($0, CTFontCreateWithName("Helvetica" as CFString, $0, nil))
        })
        let black = CGColor(gray: 0, alpha: 1)
        var pages = 0
        var y = top
        var pendingHeader = false

        func beginPage() {
            context.beginPDFPage(nil)
            pageOpen = true
            pages += 1
        }

        func lines(_ text: String, size: CGFloat, visit: (CTLine, String) throws -> Void) throws {
            try output.check()
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): fonts[size]!,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
            ]
            let value = NSAttributedString(string: text, attributes: attributes)
            let options = [kCTTypesetterOptionAllowUnboundedLayout as String: false] as CFDictionary
            guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
                value as CFAttributedString, options
            ) else { throw WriterError.layoutUnavailable }
            if value.length == 0 {
                try visit(CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0)), "")
                return
            }
            var start = 0
            while start < value.length {
                try output.check()
                var count = CTTypesetterSuggestLineBreak(typesetter, start, width)
                guard count > 0 && count <= value.length - start else { throw WriterError.layoutUnavailable }
                var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                if CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line) > width + 0.25 {
                    count = CTTypesetterSuggestClusterBreak(typesetter, start, width)
                    guard count > 0 && count <= value.length - start else { throw WriterError.layoutUnavailable }
                    line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                }
                guard CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line) <= width + 0.25
                else { throw WriterError.layoutUnavailable }
                // Wrapped spans concatenate; only the logical paragraph ends in a newline.
                let logicalText = value.attributedSubstring(from: NSRange(location: start, length: count)).string
                    + (start + count == value.length ? "\n" : "")
                try visit(line, logicalText)
                start += count
            }
        }

        func draw(_ line: CTLine, logicalText: String, baseline: CGFloat) throws {
            try output.check()
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: margin, y: baseline)
            if !logicalText.isEmpty {
                CGPDFContextBeginTag(context, .span, [
                    CGPDFTagProperty.actualText.rawValue as String: logicalText,
                ] as CFDictionary)
            }
            CTLineDraw(line, context)
            if !logicalText.isEmpty { CGPDFContextEndTag(context) }
            context.restoreGState()
            try output.check()
        }

        func nextPage(repeatingTitle: Bool = true) throws {
            // A fully consumed blank page counts; an unused trailing page does not.
            if !pageOpen { beginPage() }
            context.endPDFPage()
            pageOpen = false
            try output.check()
            y = top
            pendingHeader = repeatingTitle
        }

        func titlePrefix(_ count: Int) -> String {
            title.prefix(count).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        func ensurePage() throws {
            guard !pageOpen else { return }
            beginPage()
            if pendingHeader && !title.isEmpty {
                var headerY = mediaBox.height - 36
                try lines(titlePrefix(80), size: 8) { line, logicalText in
                    guard headerY - 14 >= bottom else { throw WriterError.layoutUnavailable }
                    try draw(line, logicalText: logicalText, baseline: headerY)
                    headerY -= 14
                }
                y = min(y, top - 10, headerY - 2)
            }
            pendingHeader = false
        }

        func drawText(
            _ text: String, size: CGFloat, extra: CGFloat = 0,
            after: CGFloat = 0, minimumAdvance: CGFloat = 14
        ) throws {
            try lines(text, size: size) { line, logicalText in
                try ensurePage()
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let advance = max(minimumAdvance, ceil(ascent + descent + leading))
                if y - advance - extra < bottom {
                    try nextPage()
                    try ensurePage()
                }
                guard y - advance - extra >= bottom else { throw WriterError.layoutUnavailable }
                y -= extra
                try draw(line, logicalText: logicalText, baseline: y)
                y -= advance + after
            }
        }

        func blank() throws {
            y -= 7
            if y < bottom { try nextPage(repeatingTitle: false) }
        }

        beginPage()
        if !title.isEmpty {
            try drawText(titlePrefix(120), size: 18, minimumAdvance: 22)
            y -= 20
        }

        var inCode = false
        var cursor = content.startIndex
        while true {
            try output.check()
            let newline = content[cursor...].firstIndex(of: "\n")
            let end = newline ?? content.endIndex
            let raw = String(content[cursor..<end]).replacingOccurrences(of: "\r", with: "")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                try blank()
            } else if inCode {
                try drawText(raw.replacingOccurrences(of: "\t", with: "    "), size: 9)
            } else if trimmed.isEmpty {
                try blank()
            } else {
                var text = trimmed
                var size: CGFloat = 11, extra: CGFloat = 0, after: CGFloat = 0
                if trimmed.hasPrefix("### ") {
                    text = String(trimmed.dropFirst(4)); size = 12; extra = 2
                } else if trimmed.hasPrefix("## ") {
                    text = String(trimmed.dropFirst(3)); size = 13; extra = 4
                } else if trimmed.hasPrefix("# ") {
                    text = String(trimmed.dropFirst(2)).uppercased(); size = 16; extra = 6; after = 4
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    text = "• " + String(trimmed.dropFirst(2))
                }
                text = text.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "`", with: "")
                text = text.split(separator: " ").joined(separator: " ")
                try drawText(text, size: size, extra: extra, after: after)
            }
            guard let newline else { break }
            cursor = content.index(after: newline)
        }

        try output.check()
        if pageOpen { context.endPDFPage() }
        pageOpen = false
        context.closePDF()
        closed = true
        try output.check()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.data.write(to: path, options: .atomic)
        return [
            "ok": true,
            "path": path.path,
            "bytes_written": output.data.count,
            "pages": pages,
            "engine": "swift-pdf-writer",
            "title": title,
        ]
    }
}

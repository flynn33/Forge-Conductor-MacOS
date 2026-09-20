// StjornarvaldNativePolicyExtractor.swift
// What: Performs bounded, native, best-effort interpretation of policy artifacts.
// How: Small files use Apple frameworks and bounded text/signature fallbacks.
// Why: Every source remains accepted even when no extractor can recover text.

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct StjornarvaldExtractedSegment: Sendable, Equatable {
    let locator: String
    let method: String
    let version: String
    let content: String
    let confidence: Double
}

struct StjornarvaldExtractionResult: Sendable, Equatable {
    let kind: PolicyArtifactKind
    let state: PolicyArtifactInterpretationState
    let metadata: [String: String]
    let segments: [StjornarvaldExtractedSegment]
    let observation: String?
}

enum StjornarvaldNativePolicyExtractor {
    static let maximumInputBytes = 1_048_576
    static let maximumSegmentBytes = 32_768
    static let maximumSegments = 64

    static func classify(url: URL, mode: mode_t, leadingBytes: Data = Data()) -> PolicyArtifactKind {
        switch mode & S_IFMT {
        case S_IFDIR:
            let lower = url.lastPathComponent.lowercased()
            if lower.hasSuffix(".app") || lower.hasSuffix(".bundle") { return .bundle }
            if lower.hasSuffix(".framework") || lower.hasSuffix(".pkg") { return .package }
            return .directory
        case S_IFLNK: return .symbolicLink
        case S_IFSOCK: return .socket
        case S_IFIFO: return .fifo
        case S_IFCHR: return .characterDevice
        case S_IFBLK: return .blockDevice
        case S_IFREG: break
        default: return .unknown
        }

        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar") || lower.hasSuffix(".gz")
            || lower.hasSuffix(".bz2") || lower.hasSuffix(".xz") || lower.hasSuffix(".7z") {
            return .archive
        }
        if leadingBytes.starts(with: Data("%PDF-".utf8)) || lower.hasSuffix(".pdf") { return .pdf }
        if isImage(path: lower, data: leadingBytes) { return .image }
        if [".mp3", ".m4a", ".wav", ".aiff", ".mp4", ".mov", ".m4v"]
            .contains(where: lower.hasSuffix) { return .media }
        if [".rtf", ".rtfd", ".html", ".htm", ".docx"].contains(where: lower.hasSuffix) {
            return .richDocument
        }
        if [".json", ".plist", ".yaml", ".yml", ".toml", ".xml"]
            .contains(where: lower.hasSuffix) { return .structuredText }
        if [".sh", ".zsh", ".bash", ".py", ".rb", ".pl"].contains(where: lower.hasSuffix) {
            return .script
        }
        if isMachO(leadingBytes) { return .executable }
        if decodedText(leadingBytes) != nil { return .text }
        return .unknownBinary
    }

    static func extract(url: URL, mode: mode_t, data: Data) -> StjornarvaldExtractionResult {
        let kind = classify(url: url, mode: mode, leadingBytes: data.prefix(512))
        var metadata = baseMetadata(url: url, kind: kind)

        if kind == .pdf {
            return extractPDF(url: url, data: data, metadata: metadata)
        }
        if kind == .richDocument {
            return extractRichDocument(url: url, data: data, metadata: metadata)
        }
        if kind == .structuredText {
            if let structured = structuredText(url: url, data: data) {
                return textResult(kind: kind, text: structured.text, method: structured.method,
                                  confidence: 0.98, metadata: metadata)
            }
        }
        if kind == .archive {
            if url.pathExtension.lowercased() == "zip", SafeZIPArchive.isZIP(data, path: url.path) {
                do {
                    let entries = try SafeZIPArchive.inspect(data)
                    metadata["archive_entry_count"] = String(entries.count)
                    let inventory = entries.prefix(2_048).map { $0.path }.joined(separator: "\n")
                    return textResult(
                        kind: kind, text: inventory, method: "native-zip-inventory",
                        confidence: 1, metadata: metadata
                    )
                } catch {
                    let detail = bounded(error.localizedDescription, maximumBytes: 512)
                    let state: PolicyArtifactInterpretationState = detail.lowercased().contains("encrypt")
                        ? .encryptedContent : .strategyError
                    return StjornarvaldExtractionResult(
                        kind: kind, state: state, metadata: metadata, segments: [],
                        observation: "Archive inventory retained metadata only: \(detail)"
                    )
                }
            }
            return metadataOnly(kind: kind, metadata: metadata, observation: "No bounded native archive inventory strategy was available.")
        }
        if kind == .image {
            #if canImport(ImageIO)
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                if let width = properties[kCGImagePropertyPixelWidth] { metadata["pixel_width"] = "\(width)" }
                if let height = properties[kCGImagePropertyPixelHeight] { metadata["pixel_height"] = "\(height)" }
                metadata["image_count"] = String(CGImageSourceGetCount(source))
                let text = metadata.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                return textResult(kind: kind, text: text, method: "imageio-metadata",
                                  confidence: 1, metadata: metadata)
            }
            #endif
            return metadataOnly(kind: kind, metadata: metadata, observation: "Image metadata could not be decoded.")
        }
        if let decoded = decodedText(data) {
            metadata["text_encoding"] = decoded.encoding
            return textResult(kind: kind == .unknownBinary ? .text : kind, text: decoded.text,
                              method: "native-text", confidence: 1, metadata: metadata)
        }
        if kind == .executable {
            metadata["binary_signature"] = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            return metadataOnly(kind: kind, metadata: metadata, observation: "Executable metadata was cataloged without launching it.")
        }
        if kind == .media {
            return metadataOnly(kind: kind, metadata: metadata, observation: "Media metadata was cataloged; no timed text was available in the bounded pass.")
        }

        let strings = printableStrings(data).joined(separator: "\n")
        if !strings.isEmpty {
            return textResult(kind: .unknownBinary, text: strings, method: "bounded-printable-strings",
                              confidence: 0.25, metadata: metadata)
        }
        return metadataOnly(kind: kind, metadata: metadata, observation: "No direct text was recoverable; metadata remains active.")
    }

    static func metadataOnly(
        kind: PolicyArtifactKind,
        metadata: [String: String],
        observation: String
    ) -> StjornarvaldExtractionResult {
        StjornarvaldExtractionResult(
            kind: kind, state: .metadataOnly, metadata: metadata,
            segments: [], observation: observation
        )
    }

    private static func textResult(
        kind: PolicyArtifactKind,
        text: String,
        method: String,
        confidence: Double,
        metadata: [String: String]
    ) -> StjornarvaldExtractionResult {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chunks = boundedUTF8Chunks(normalized)
        if chunks.isEmpty {
            return metadataOnly(kind: kind, metadata: metadata, observation: "The artifact contained no recoverable non-empty text.")
        }
        let truncated = chunks.count == maximumSegments
            && normalized.utf8.count > chunks.reduce(0) { $0 + $1.utf8.count }
        let segments = chunks.enumerated().map { index, content in
            StjornarvaldExtractedSegment(
                locator: "segment:\(index)", method: method, version: "1",
                content: content, confidence: confidence
            )
        }
        return StjornarvaldExtractionResult(
            kind: kind, state: truncated ? .partiallyIndexed : .indexed,
            metadata: metadata, segments: segments,
            observation: truncated ? "Text exceeded the bounded segment budget and remains partially indexed." : nil
        )
    }

    private static func extractPDF(
        url: URL,
        data: Data,
        metadata: [String: String]
    ) -> StjornarvaldExtractionResult {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            return metadataOnly(kind: .pdf, metadata: metadata, observation: "PDFKit could not open the document.")
        }
        var values = metadata
        values["page_count"] = String(document.pageCount)
        guard !document.isEncrypted else {
            return StjornarvaldExtractionResult(
                kind: .pdf, state: .encryptedContent, metadata: values,
                segments: [], observation: "Encrypted PDF content remains accepted and metadata-only."
            )
        }
        let text = (0..<min(document.pageCount, 256)).compactMap { index in
            document.page(at: index)?.string.map { "[page \(index + 1)]\n\($0)" }
        }.joined(separator: "\n\n")
        return textResult(kind: .pdf, text: text, method: "pdfkit-text", confidence: 0.98, metadata: values)
        #else
        return metadataOnly(kind: .pdf, metadata: metadata, observation: "PDFKit is unavailable on this build host.")
        #endif
    }

    private static func extractRichDocument(
        url: URL,
        data: Data,
        metadata: [String: String]
    ) -> StjornarvaldExtractionResult {
        #if canImport(AppKit)
        let lower = url.lastPathComponent.lowercased()
        let type: NSAttributedString.DocumentType
        if lower.hasSuffix(".rtf") || lower.hasSuffix(".rtfd") { type = .rtf }
        else if lower.hasSuffix(".docx") { type = .officeOpenXML }
        else { type = .html }
        do {
            let attributed = try NSAttributedString(
                data: data, options: [.documentType: type], documentAttributes: nil
            )
            return textResult(kind: .richDocument, text: attributed.string,
                              method: "appkit-\(type.rawValue)", confidence: 0.95, metadata: metadata)
        } catch {
            return metadataOnly(
                kind: .richDocument, metadata: metadata,
                observation: "Native rich-document interpretation failed: \(bounded(error.localizedDescription, maximumBytes: 512))"
            )
        }
        #else
        return metadataOnly(kind: .richDocument, metadata: metadata, observation: "AppKit is unavailable on this build host.")
        #endif
    }

    private static func structuredText(url: URL, data: Data) -> (text: String, method: String)? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: canonical, encoding: .utf8) {
            return (text, "foundation-json")
        }
        if lower.hasSuffix(".plist"),
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0),
           let text = String(data: xml, encoding: .utf8) {
            return (text, "foundation-plist")
        }
        return decodedText(data).map { ($0.text, "native-structured-text") }
    }

    private static func decodedText(_ data: Data) -> (text: String, encoding: String)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) { return (value, "utf-8-bom") }
        if data.starts(with: [0xFF, 0xFE]),
           let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (value, "utf-16le-bom") }
        if data.starts(with: [0xFE, 0xFF]),
           let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (value, "utf-16be-bom") }
        guard !data.contains(0), let value = String(data: data, encoding: .utf8) else { return nil }
        let controlCount = value.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" { count += 1 }
        }
        guard controlCount <= max(4, value.unicodeScalars.count / 100) else { return nil }
        return (value, "utf-8")
    }

    private static func baseMetadata(url: URL, kind: PolicyArtifactKind) -> [String: String] {
        var values = ["filename": url.lastPathComponent, "artifact_kind": kind.rawValue]
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { values["extension"] = ext }
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext) { values["content_type"] = type.identifier }
        #endif
        return values
    }

    private static func boundedUTF8Chunks(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        for character in value {
            let bytes = String(character).utf8.count
            if currentBytes + bytes > maximumSegmentBytes, !current.isEmpty {
                result.append(current)
                if result.count == maximumSegments { return result }
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty, result.count < maximumSegments { result.append(current) }
        return result
    }

    private static func printableStrings(_ data: Data) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        for byte in data.prefix(65_536) {
            if (32...126).contains(byte) || byte == 9 {
                current.append(byte)
            } else {
                if current.count >= 8 { result.append(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
                if result.count == 128 { break }
            }
        }
        if current.count >= 8, result.count < 128 { result.append(String(decoding: current, as: UTF8.self)) }
        return result
    }

    private static func isImage(path: String, data: Data) -> Bool {
        if [".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".tif", ".tiff", ".bmp"]
            .contains(where: path.hasSuffix) { return true }
        return data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: Data("GIF8".utf8))
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = Array(data.prefix(4))
        return magic == [0xFE, 0xED, 0xFA, 0xCE]
            || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xFE, 0xED, 0xFA, 0xCF]
            || magic == [0xCF, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE]
            || magic == [0xBE, 0xBA, 0xFE, 0xCA]
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            if count + width > maximumBytes { break }
            result.append(character)
            count += width
        }
        return result
    }
}

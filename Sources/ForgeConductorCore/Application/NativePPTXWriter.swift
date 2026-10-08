import Foundation

enum NativePPTXError: Error, Equatable, LocalizedError {
    case workerRequired, invalidSlides, contentTooLarge, invalidText, outputTooLarge, structureTooLarge

    var code: String {
        switch self {
        case .workerRequired: "pptx_worker_required"
        case .invalidSlides: "invalid_slides"
        case .contentTooLarge: "content_too_large"
        case .invalidText: "invalid_text"
        case .outputTooLarge: "pptx_output_too_large"
        case .structureTooLarge: "pptx_structure_too_large"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "PPTX encoding requires a worker thread"
        case .invalidSlides: "slides must contain objects with a string title and an array of string paragraphs"
        case .contentTooLarge: "PPTX text is limited to 1–32 slides, 1024 paragraphs including nonempty titles, 4096 UTF-8 bytes per title or paragraph, and 65536 total text bytes"
        case .invalidText: "PPTX text contains a character disallowed by XML 1.0"
        case .outputTooLarge: "Encoded PPTX is limited to 1048576 bytes"
        case .structureTooLarge: "Each PPTX slide is limited to 32768 XML elements; line breaks contribute to this limit"
        }
    }
}

/// Call-local text slides; fixed geometry does not promise that every paragraph fits visually.
/// CRLF/CR become LF; LF is a soft break within each title/paragraph, without OOXML escape decoding.
enum NativePPTXWriter {
    struct Slide: Equatable, Sendable {
        let title: String
        let paragraphs: [String]
    }

    static let maximumSlides = 32
    static let maximumParagraphs = 1024
    static let maximumParagraphBytes = 4096
    static let maximumTextBytes = 65_536
    static let maximumOutputBytes = 1_048_576
    static let maximumSlideXMLNodes = NativePPTXReader.maximumXMLNodes
    static let textContract = "pptx-text-slides-v1"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let namespaces = "xmlns:p=\"\(presentation)\" xmlns:a=\"\(drawing)\" xmlns:r=\"\(officeRelationships)\""
    private static let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    static func slides(from value: Any?) throws -> [Slide] {
        guard let rawSlides = value as? [Any], !rawSlides.isEmpty else { throw NativePPTXError.invalidSlides }
        guard rawSlides.count <= maximumSlides else { throw NativePPTXError.contentTooLarge }
        var slides: [Slide] = []
        var paragraphs = 0
        for raw in rawSlides {
            guard let object = raw as? [String: Any], Set(object.keys) == ["title", "paragraphs"],
                  let title = object["title"] as? String, let body = object["paragraphs"] as? [Any] else {
                throw NativePPTXError.invalidSlides
            }
            let titleCount = title.isEmpty ? 0 : 1
            guard body.count <= maximumParagraphs - titleCount,
                  paragraphs <= maximumParagraphs - body.count - titleCount else { throw NativePPTXError.contentTooLarge }
            guard body.allSatisfy({ $0 is String }) else { throw NativePPTXError.invalidSlides }
            slides.append(Slide(title: title, paragraphs: body.map { $0 as! String }))
            paragraphs += body.count + titleCount
        }
        return slides
    }

    static func encode(slides: [Slide], cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> Data {
        guard !Thread.isMainThread else { throw NativePPTXError.workerRequired }
        try check(cancellation)
        try validate(slides, cancellation: cancellation)
        guard (1...maximumOutputBytes).contains(outputByteLimit) else { throw NativePPTXError.outputTooLarge }
        var zip = StoredZIP(limit: outputByteLimit)
        var types = BoundedBytes(limit: outputByteLimit)
        try types.append(header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>")
        for (name, type) in [("presentation", "presentation.main"), ("presProps", "presProps"),
                             ("slideMasters/slideMaster1", "slideMaster"), ("slideLayouts/slideLayout1", "slideLayout")] {
            try types.append("<Override PartName=\"/ppt/\(name).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\(type)+xml\"/>")
        }
        try types.append("<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>")
        for index in slides.indices {
            try check(cancellation)
            try types.append("<Override PartName=\"/ppt/slides/slide\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>")
        }
        try types.append("</Types>")
        try zip.add("[Content_Types].xml", bytes: types.data, cancellation: cancellation)
        try zip.add("_rels/.rels", xml: relationships([("rId1", "officeDocument", "ppt/presentation.xml")]), cancellation: cancellation)
        var main = BoundedBytes(limit: outputByteLimit)
        try main.append(header + "<p:presentation \(namespaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>")
        var relations = [("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
                         ("rId2", "presProps", "presProps.xml"), ("rId3", "theme", "theme/theme1.xml")]
        for index in slides.indices {
            try check(cancellation)
            try main.append("<p:sldId id=\"\(index + 256)\" r:id=\"rId\(index + 4)\"/>")
            relations.append(("rId\(index + 4)", "slide", "slides/slide\(index + 1).xml"))
        }
        try main.append("</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\" type=\"screen4x3\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/><p:defaultTextStyle/></p:presentation>")
        try zip.add("ppt/presentation.xml", bytes: main.data, cancellation: cancellation)
        try zip.add("ppt/_rels/presentation.xml.rels", xml: relationships(relations), cancellation: cancellation)
        try zip.add("ppt/presProps.xml", xml: header + "<p:presentationPr \(namespaces)/>", cancellation: cancellation)
        try zip.add("ppt/slideLayouts/slideLayout1.xml", xml: header + "<p:sldLayout \(namespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>", cancellation: cancellation)
        try zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", xml: relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]), cancellation: cancellation)
        try zip.add("ppt/slideMasters/slideMaster1.xml", xml: header + "<p:sldMaster \(namespaces)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>", cancellation: cancellation)
        try zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", xml: relationships([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]), cancellation: cancellation)
        try zip.add("ppt/theme/theme1.xml", xml: theme(), cancellation: cancellation)
        for (index, slide) in slides.enumerated() {
            try check(cancellation)
            var xml = BoundedBytes(limit: outputByteLimit, xmlNodeLimit: maximumSlideXMLNodes)
            try xml.append(header + "<p:sld \(namespaces)><p:cSld><p:spTree>\(group)")
            if !slide.title.isEmpty { try appendShape([slide.title], title: true, to: &xml, cancellation: cancellation) }
            if !slide.paragraphs.isEmpty { try appendShape(slide.paragraphs, title: false, to: &xml, cancellation: cancellation) }
            try xml.append("</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            try zip.add("ppt/slides/slide\(index + 1).xml", bytes: xml.data, cancellation: cancellation)
            try zip.add("ppt/slides/_rels/slide\(index + 1).xml.rels", xml: relationships([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]), cancellation: cancellation)
        }
        return try zip.finish(cancellation: cancellation)
    }

    private static func check(_ cancellation: ToolCallCancellation?) throws {
        try cancellation?.checkCancellation()
        if Task.isCancelled { throw CancellationError() }
    }

    private static func validate(_ slides: [Slide], cancellation: ToolCallCancellation?) throws {
        guard !slides.isEmpty else { throw NativePPTXError.invalidSlides }
        guard slides.count <= maximumSlides else { throw NativePPTXError.contentTooLarge }
        var paragraphs = 0, total = 0
        for slide in slides {
            try check(cancellation)
            let titleCount = slide.title.isEmpty ? 0 : 1
            guard slide.paragraphs.count <= maximumParagraphs - titleCount,
                  paragraphs <= maximumParagraphs - slide.paragraphs.count - titleCount else { throw NativePPTXError.contentTooLarge }
            paragraphs += slide.paragraphs.count + titleCount
            for text in [slide.title] + slide.paragraphs {
                try check(cancellation)
                let count = text.utf8.prefix(maximumParagraphBytes + 1).count
                guard count <= maximumParagraphBytes, total <= maximumTextBytes - count else { throw NativePPTXError.contentTooLarge }
                total += count
                guard text.unicodeScalars.allSatisfy({ scalar in
                    let value = scalar.value
                    return value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value)
                        || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
                }) else { throw NativePPTXError.invalidText }
            }
        }
    }

    private static func appendShape(_ paragraphs: [String], title: Bool, to xml: inout BoundedBytes,
                                    cancellation: ToolCallCancellation?) throws {
        let size = title ? 3200 : 2000
        try xml.append("<p:sp><p:nvSpPr><p:cNvPr id=\"\(title ? 2 : 3)\" name=\"\(title ? "Title" : "Body")\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"457200\" y=\"\(title ? 274320 : 1371600)\"/><a:ext cx=\"8229600\" cy=\"\(title ? 914400 : 5029200)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"square\" anchor=\"t\"><a:noAutofit/></a:bodyPr><a:lstStyle/>")
        let run = "<a:r><a:rPr lang=\"en-US\" sz=\"\(size)\"/><a:t xml:space=\"preserve\">"
        for text in paragraphs {
            try check(cancellation)
            try xml.append("<a:p><a:pPr><a:buNone/></a:pPr>" + run)
            let scalars = text.unicodeScalars
            var index = scalars.startIndex, visited = 0
            while index < scalars.endIndex {
                if visited % 128 == 0 { try check(cancellation) }; visited += 1
                let value = scalars[index].value
                switch value {
                case 38: try xml.append("&amp;")
                case 60: try xml.append("&lt;")
                case 62: try xml.append("&gt;")
                case 10, 13:
                    try xml.append("</a:t></a:r><a:br/>" + run)
                    if value == 13 {
                        let next = scalars.index(after: index)
                        if next < scalars.endIndex, scalars[next].value == 10 { index = next }
                    }
                default: try xml.append(String(scalars[index]))
                }
                index = scalars.index(after: index)
            }
            try xml.append("</a:t></a:r><a:endParaRPr lang=\"en-US\" sz=\"\(size)\"/></a:p>")
        }
        try xml.append("</p:txBody></p:sp>")
    }

    private static func relationships(_ items: [(String, String, String)]) -> String {
        header + "<Relationships xmlns=\"\(packageRelationships)\">"
            + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(officeRelationships)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined()
            + "</Relationships>"
    }

    private static func theme() -> String {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "202020"), ("lt2", "EEEEEE"),
                      ("accent1", "4472C4"), ("accent2", "ED7D31"), ("accent3", "A5A5A5"), ("accent4", "FFC000"),
                      ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0000FF"), ("folHlink", "800080")]
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        let font = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        return header + "<a:theme xmlns:a=\"\(drawing)\" name=\"Default\"><a:themeElements><a:clrScheme name=\"Default\">"
            + colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
            + "</a:clrScheme><a:fontScheme name=\"Default\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme><a:fmtScheme name=\"Default\"><a:fillStyleLst>"
            + String(repeating: fill, count: 3) + "</a:fillStyleLst><a:lnStyleLst>" + String(repeating: line, count: 3)
            + "</a:lnStyleLst><a:effectStyleLst>" + String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
            + "</a:effectStyleLst><a:bgFillStyleLst>" + String(repeating: fill, count: 3)
            + "</a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
    }

    private static func crc32(_ bytes: Data, cancellation: ToolCallCancellation?) throws -> UInt32 {
        var checksum: UInt32 = 0xFFFFFFFF
        for (index, byte) in bytes.enumerated() {
            if index % 4096 == 0 { try check(cancellation) }
            checksum ^= UInt32(byte)
            for _ in 0..<8 { checksum = (checksum >> 1) ^ ((checksum & 1) == 1 ? 0xEDB88320 : 0) }
        }
        return checksum ^ 0xFFFFFFFF
    }

    private struct StoredZIP {
        let limit: Int
        var body: BoundedBytes
        var directory: BoundedBytes
        var count: UInt16 = 0

        init(limit: Int) { self.limit = limit; body = BoundedBytes(limit: limit); directory = BoundedBytes(limit: limit) }
        mutating func add(_ name: String, xml: String, cancellation: ToolCallCancellation?) throws {
            try add(name, bytes: Data(xml.utf8), cancellation: cancellation)
        }
        mutating func add(_ name: String, bytes: Data, cancellation: ToolCallCancellation?) throws {
            try check(cancellation)
            let nameBytes = Array(name.utf8)
            // Reserve both records and the final EOCD before appending any part bytes.
            let required = bytes.count + 30 + nameBytes.count + 46 + nameBytes.count + 22
            guard required <= limit - body.data.count - directory.data.count else { throw NativePPTXError.outputTooLarge }
            let offset = UInt32(body.data.count), size = UInt32(bytes.count)
            let checksum = try crc32(bytes, cancellation: cancellation)
            try body.append32(0x04034b50)
            for value in [20, 0x0800, 0, 0, 0x0021] as [UInt16] { try body.append16(value) }
            for value in [checksum, size, size] { try body.append32(value) }
            try body.append16(UInt16(nameBytes.count)); try body.append16(0); try body.append(nameBytes); try body.append(bytes)
            try directory.append32(0x02014b50)
            for value in [20, 20, 0x0800, 0, 0, 0x0021] as [UInt16] { try directory.append16(value) }
            for value in [checksum, size, size] { try directory.append32(value) }
            for value in [UInt16(nameBytes.count), 0, 0, 0, 0] { try directory.append16(value) }
            try directory.append32(0); try directory.append32(offset); try directory.append(nameBytes); count += 1
        }
        mutating func finish(cancellation: ToolCallCancellation?) throws -> Data {
            try check(cancellation)
            let offset = UInt32(body.data.count)
            try body.append(directory.data); try body.append32(0x06054b50)
            for value in [0, 0, count, count] as [UInt16] { try body.append16(value) }
            try body.append32(UInt32(directory.data.count)); try body.append32(offset); try body.append16(0)
            try check(cancellation)
            return body.data
        }
    }

    private struct BoundedBytes {
        let limit: Int
        let xmlNodeLimit: Int?
        private(set) var data = Data()
        private var xmlNodes = 0

        init(limit: Int, xmlNodeLimit: Int? = nil) { self.limit = limit; self.xmlNodeLimit = xmlNodeLimit }
        mutating func append(_ text: String) throws {
            if let xmlNodeLimit {
                // Markup chunks are complete; user scalars '<' and '>' are escaped before this boundary.
                var bytes = text.utf8.makeIterator(), added = 0
                while let byte = bytes.next() {
                    if byte == 60, let next = bytes.next(), next != 47, next != 63, next != 33 { added += 1 }
                }
                guard added <= xmlNodeLimit - xmlNodes else { throw NativePPTXError.structureTooLarge }
                xmlNodes += added
            }
            try append(text.utf8)
        }
        mutating func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
            guard bytes.count <= limit - data.count else { throw NativePPTXError.outputTooLarge }
            data.append(contentsOf: bytes)
        }
        mutating func append16(_ value: UInt16) throws { try append([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        mutating func append32(_ value: UInt32) throws {
            try append([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
        }
    }
}

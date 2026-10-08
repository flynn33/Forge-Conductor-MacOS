import Foundation

/// Extracts bounded, slide-ordered DrawingML text, without following notes,
/// layouts, masters, charts or external relationships. Original decks are retained.
enum NativePPTXReader {
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): "The presentation could not be converted: \(detail)" }
        }
    }

    static let maximumContainerBytes = 16 * 1_048_576
    static let maximumParts = 256
    static let maximumPartBytes = 2 * 1_048_576
    static let maximumExpandedBytes = 8 * 1_048_576
    static let maximumSlides = 32
    static let maximumParagraphs = 1_024
    static let maximumParagraphBytes = 4_096
    static let maximumTextBytes = 128 * 1_024
    static let maximumXMLNodes = 32_768
    static let maximumXMLDepth = 32

    private static let presentationNamespaces = [
        "http://schemas.openxmlformats.org/presentationml/2006/main",
        "http://purl.oclc.org/ooxml/presentationml/main",
    ]
    private static let drawingNamespaces = [
        "http://schemas.openxmlformats.org/drawingml/2006/main",
        "http://purl.oclc.org/ooxml/drawingml/main",
    ]
    private static let relationshipNamespaces = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships",
    ]
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"

    static func text(in data: Data) throws -> String {
        try checkCancellation()
        guard data.count <= maximumContainerBytes else { throw Failure.invalid("container byte limit exceeded") }
        let entries = try SafeZIPArchive.inspect(data)
        guard entries.count <= maximumParts,
              entries.allSatisfy({ $0.uncompressedBytes <= maximumPartBytes }),
              entries.reduce(0, { $0 + $1.uncompressedBytes }) <= maximumExpandedBytes else {
            throw Failure.invalid("part or expanded-byte limit exceeded")
        }
        let available = Set(entries.filter { !$0.isDirectory }.map(\.path))
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pptx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try SafeZIPArchive.extract(data, to: stage, expected: entries)
        func part(_ path: String) throws -> Element {
            try checkCancellation()
            guard available.contains(path) else { throw Failure.invalid("a required package part is missing") }
            return try parse(Data(contentsOf: stage.appendingPathComponent(path)))
        }

        let roots = try relationships(try part("_rels/.rels"))
        let offices = roots.filter { relationshipNamespaces.map { $0 + "/officeDocument" }.contains($0.type) }
        guard offices.count == 1 else { throw Failure.invalid("exactly one presentation relationship is required") }
        let presentationPath = try target(offices[0], relativeTo: "")
        let presentation = try part(presentationPath)
        try require(presentation, name: "presentation", namespaces: presentationNamespaces)
        let lists = presentation.children(named: "sldIdLst", namespaces: presentationNamespaces)
        guard lists.count <= 1 else { throw Failure.invalid("duplicate slide list") }
        let slides = lists.first?.children(named: "sldId", namespaces: presentationNamespaces) ?? []
        guard slides.count <= maximumSlides else { throw Failure.invalid("slide count limit exceeded") }
        if slides.isEmpty { return "" }
        let relations = try relationships(try part(relationshipPath(for: presentationPath)))
        let byID = Dictionary(uniqueKeysWithValues: relations.map { ($0.id, $0) })
        var seenIDs: Set<String> = [], seenNumbers: Set<UInt32> = [], seenPaths: Set<String> = []
        var paragraphCount = 0, output = ""
        for (index, slide) in slides.enumerated() {
            try checkCancellation()
            let references = relationshipNamespaces.compactMap { slide.attributes[$0 + "|id"] }
            guard references.count == 1, let id = references.first, seenIDs.insert(id).inserted,
                  let number = slide.attributes["id"], !number.isEmpty, number.utf8.count <= 10,
                  number.utf8.allSatisfy({ (48...57).contains($0) }), let numericID = UInt32(number),
                  seenNumbers.insert(numericID).inserted,
                  let relation = byID[id], relationshipNamespaces.map({ $0 + "/slide" }).contains(relation.type) else {
                throw Failure.invalid("slide identity or relationship is invalid")
            }
            let path = try target(relation, relativeTo: presentationPath)
            guard seenPaths.insert(path).inserted else { throw Failure.invalid("duplicate slide target") }
            let root = try part(path)
            try require(root, name: "sld", namespaces: presentationNamespaces)
            let contents = root.children(named: "cSld", namespaces: presentationNamespaces)
            guard contents.count == 1 else { throw Failure.invalid("exactly one slide content body is required") }
            let trees = contents[0].children(named: "spTree", namespaces: presentationNamespaces)
            guard trees.count == 1 else { throw Failure.invalid("exactly one slide shape tree is required") }
            var slideText = "", hasParagraph = false
            try visitShapes(trees[0], paragraphCount: &paragraphCount, text: &slideText, hasParagraph: &hasParagraph)
            if !slideText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let prefix = (output.isEmpty ? "" : "\n\n") + "[Slide \(index + 1)]\n"
                guard prefix.utf8.count <= maximumTextBytes - output.utf8.count,
                      slideText.utf8.count <= maximumTextBytes - output.utf8.count - prefix.utf8.count else {
                    throw Failure.invalid("extracted text byte limit exceeded")
                }
                output += prefix + slideText
            }
        }
        try checkCancellation()
        return output
    }

    private static func visitShapes(_ tree: Element, paragraphCount: inout Int,
                                    text: inout String, hasParagraph: inout Bool) throws {
        for shape in tree.children where presentationNamespaces.contains(shape.namespace) {
            try checkCancellation()
            switch shape.name {
            case "sp":
                let bodies = shape.children(named: "txBody", namespaces: presentationNamespaces)
                guard bodies.count <= 1 else { throw Failure.invalid("duplicate shape text body") }
                if let body = bodies.first {
                    try appendParagraphs(body, paragraphCount: &paragraphCount, text: &text, hasParagraph: &hasParagraph)
                }
            case "grpSp":
                try visitShapes(shape, paragraphCount: &paragraphCount, text: &text, hasParagraph: &hasParagraph)
            case "graphicFrame":
                for graphic in shape.children(named: "graphic", namespaces: drawingNamespaces) {
                    for data in graphic.children(named: "graphicData", namespaces: drawingNamespaces) {
                        for table in data.children(named: "tbl", namespaces: drawingNamespaces) {
                            for row in table.children(named: "tr", namespaces: drawingNamespaces) {
                                for cell in row.children(named: "tc", namespaces: drawingNamespaces) {
                                    let bodies = cell.children(named: "txBody", namespaces: drawingNamespaces)
                                    guard bodies.count <= 1 else { throw Failure.invalid("duplicate table-cell text body") }
                                    if let body = bodies.first {
                                        try appendParagraphs(body, paragraphCount: &paragraphCount, text: &text, hasParagraph: &hasParagraph)
                                    }
                                }
                            }
                        }
                    }
                }
            default: break
            }
        }
    }

    private static func appendParagraphs(_ body: Element, paragraphCount: inout Int,
                                         text: inout String, hasParagraph: inout Bool) throws {
        for paragraph in body.children(named: "p", namespaces: drawingNamespaces) {
            try checkCancellation()
            guard paragraphCount < maximumParagraphs else { throw Failure.invalid("paragraph count limit exceeded") }
            paragraphCount += 1
            let value = try paragraphText(paragraph)
            let separator = hasParagraph ? 1 : 0
            guard separator <= maximumTextBytes - text.utf8.count,
                  value.utf8.count <= maximumTextBytes - text.utf8.count - separator else {
                throw Failure.invalid("extracted text byte limit exceeded")
            }
            if hasParagraph { text += "\n" }
            text += value
            hasParagraph = true
        }
    }

    private static func paragraphText(_ paragraph: Element) throws -> String {
        guard paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalid("text outside a DrawingML text run")
        }
        var value = ""
        for child in paragraph.children {
            try checkCancellation()
            guard drawingNamespaces.contains(child.namespace) else {
                throw Failure.invalid("unsupported paragraph namespace")
            }
            let fragment: String
            switch child.name {
            case "r", "fld":
                let strings = child.children(named: "t", namespaces: drawingNamespaces)
                guard strings.count == 1, strings[0].children.isEmpty,
                      child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      child.children.allSatisfy({ drawingNamespaces.contains($0.namespace)
                          && ["t", "rPr", "pPr"].contains($0.name) }) else {
                    throw Failure.invalid("malformed DrawingML text run")
                }
                // DrawingML a:t is an XML string, not SpreadsheetML ST_Xstring.
                fragment = strings[0].text
            case "br":
                guard child.children.allSatisfy({ drawingNamespaces.contains($0.namespace) && $0.name == "rPr" }),
                      child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure.invalid("malformed DrawingML line break")
                }
                fragment = "\n"
            case "pPr", "endParaRPr": continue
            default: throw Failure.invalid("unsupported paragraph content")
            }
            guard fragment.utf8.count <= maximumParagraphBytes - value.utf8.count else {
                throw Failure.invalid("paragraph text byte limit exceeded")
            }
            value += fragment
        }
        return value
    }

    private struct Relationship {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    private static func relationships(_ root: Element) throws -> [Relationship] {
        try require(root, name: "Relationships", namespaces: [packageRelationships])
        var ids: Set<String> = []
        return try root.children(named: "Relationship", namespaces: [packageRelationships]).map { node in
            guard let id = node.attributes["Id"], !id.isEmpty, id.utf8.count <= 256, ids.insert(id).inserted,
                  let type = node.attributes["Type"], let target = node.attributes["Target"],
                  node.attributes["TargetMode"] == nil || ["Internal", "External"].contains(node.attributes["TargetMode"]!) else {
                throw Failure.invalid("malformed or duplicate package relationship")
            }
            return Relationship(id: id, type: type, target: target, external: node.attributes["TargetMode"] == "External")
        }
    }

    private static func relationshipPath(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "" : parent + "/") + "_rels/" + (path as NSString).lastPathComponent + ".rels"
    }

    private static func target(_ relationship: Relationship, relativeTo source: String) throws -> String {
        let value = relationship.target
        guard !relationship.external, !value.isEmpty,
              !value.contains(where: { $0 == ":" || $0 == "\\" || $0 == "?" || $0 == "#" || $0 == "%" }),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalid("external or unsupported part target")
        }
        var components = value.hasPrefix("/") || source.isEmpty
            ? [] : (source as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in value.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw Failure.invalid("part target escapes the package") }
                components.removeLast()
            } else { components.append(String(component)) }
        }
        guard !components.isEmpty else { throw Failure.invalid("empty part target") }
        return components.joined(separator: "/")
    }

    private static func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
    private static func require(_ root: Element, name: String, namespaces: [String]) throws {
        guard root.name == name, namespaces.contains(root.namespace) else { throw Failure.invalid("unexpected XML root or namespace") }
    }

    private final class Element {
        let name: String
        let namespace: String
        let attributes: [String: String]
        var text = ""
        var children: [Element] = []
        init(name: String, namespace: String, attributes: [String: String]) {
            self.name = name; self.namespace = namespace; self.attributes = attributes
        }
        func children(named name: String, namespaces: [String]) -> [Element] {
            children.filter { $0.name == name && namespaces.contains($0.namespace) }
        }
    }

    private static func parse(_ data: Data) throws -> Element {
        try checkCancellation()
        guard data.count <= maximumPartBytes, let text = String(data: data, encoding: .utf8),
              hasUTF8Declaration(text),
              try containsNoDeclarations(text) else {
            throw Failure.invalid("XML must be bounded UTF-8 without a DTD or entity declaration")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let delegate = Parser()
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.error { throw error }
        guard parsed, let root = delegate.root, delegate.stack.isEmpty else { throw Failure.invalid("malformed XML") }
        try checkCancellation()
        return root
    }

    private static func hasUTF8Declaration(_ text: String) -> Bool {
        let body = text.first == "\u{FEFF}" ? text.dropFirst() : text[...]
        guard body.hasPrefix("<?xml"), body.count > 5,
              " \t\r\n".contains(body[body.index(body.startIndex, offsetBy: 5)]) else { return true }
        guard let end = body.range(of: "?>") else { return false }
        let declaration = body[..<end.lowerBound]
        guard let encoding = declaration.range(of: #"\bencoding[ \t\r\n]*=[ \t\r\n]*(['"])([^'"]+)\1"#,
                                                options: .regularExpression) else { return true }
        let assignment = declaration[encoding]
        guard let quote = assignment.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return false }
        return assignment[assignment.index(after: quote)..<assignment.index(before: assignment.endIndex)]
            .lowercased() == "utf-8"
    }

    private static func containsNoDeclarations(_ text: String) throws -> Bool {
        var cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: "<") {
            try checkCancellation()
            let suffix = text[start...]
            let marker: String?
            if suffix.hasPrefix("<!--") { marker = "-->" }
            else if suffix.hasPrefix("<![CDATA[") { marker = "]]>" }
            else if suffix.hasPrefix("<?") { marker = "?>" }
            else { marker = nil }
            if let marker {
                guard let end = text.range(of: marker, range: start..<text.endIndex) else {
                    throw Failure.invalid("unterminated XML comment, CDATA or processing instruction")
                }
                cursor = end.upperBound
            } else {
                if suffix.hasPrefix("<!DOCTYPE") || suffix.hasPrefix("<!ENTITY") { return false }
                cursor = text.index(after: start)
            }
        }
        return true
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [(element: Element, prefixes: [String: String])] = []
        var error: Error?
        private var count = 0, textBytes = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            count += 1
            guard count <= maximumXMLNodes, stack.count < maximumXMLDepth, !Task.isCancelled else {
                error = Task.isCancelled ? CancellationError() : Failure.invalid("XML element or depth limit exceeded")
                parser.abortParsing(); return
            }
            var prefixes = stack.last?.prefixes ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
            for (key, value) in attributes {
                if key == "xmlns" { prefixes[""] = value }
                else if key.hasPrefix("xmlns:") { prefixes[String(key.dropFirst(6))] = value }
            }
            func expanded(_ name: String, attribute: Bool) -> (String, String) {
                let pieces = name.split(separator: ":", maxSplits: 1).map(String.init)
                return pieces.count == 2 ? (pieces[1], prefixes[pieces[0]] ?? "") : (name, attribute ? "" : prefixes[""] ?? "")
            }
            let (local, namespace) = expanded(elementName, attribute: false)
            var normalized: [String: String] = [:]
            for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
                let (local, namespace) = expanded(key, attribute: true)
                let expandedName = namespace.isEmpty ? local : namespace + "|" + local
                guard normalized.updateValue(value, forKey: expandedName) == nil else {
                    error = Failure.invalid("duplicate expanded XML attribute"); parser.abortParsing(); return
                }
            }
            let node = Element(name: local, namespace: namespace, attributes: normalized)
            if let parent = stack.last?.element { parent.children.append(node) }
            else if root == nil { root = node }
            else { error = Failure.invalid("multiple XML roots"); parser.abortParsing(); return }
            stack.append((node, prefixes))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBytes += string.utf8.count
            guard textBytes <= maximumPartBytes, !Task.isCancelled else {
                error = Task.isCancelled ? CancellationError() : Failure.invalid("XML text limit exceeded")
                parser.abortParsing(); return
            }
            stack.last?.element.text += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else {
                error = Failure.invalid("invalid XML CDATA"); parser.abortParsing(); return
            }
            self.parser(parser, foundCharacters: string)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}

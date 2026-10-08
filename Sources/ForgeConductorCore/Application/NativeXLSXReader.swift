import Foundation

/// A bounded value-only SpreadsheetML reader. Formulas are never evaluated and
/// external relationships are never followed. The importer retains the workbook.
enum NativeXLSXReader {
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): "The workbook could not be converted: \(detail)" }
        }
    }

    static let maximumContainerBytes = 16 * 1_048_576
    static let maximumParts = 256
    static let maximumPartBytes = 2 * 1_048_576
    static let maximumExpandedBytes = 8 * 1_048_576
    static let maximumSheets = 16
    static let maximumCells = 4_096
    static let maximumCellBytes = 4_096
    static let maximumTextBytes = 128 * 1_024

    private static let spreadsheetNamespaces = [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main",
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
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try SafeZIPArchive.extract(data, to: stage, expected: entries)
        func part(_ path: String) throws -> Element {
            try checkCancellation()
            guard available.contains(path) else { throw Failure.invalid("a required package part is missing") }
            return try parse(Data(contentsOf: stage.appendingPathComponent(path)))
        }
        let rootRelationships = try relationships(try part("_rels/.rels"))
        let offices = rootRelationships.filter { relationshipNamespaces.map { $0 + "/officeDocument" }.contains($0.type) }
        guard offices.count == 1 else { throw Failure.invalid("exactly one workbook relationship is required") }
        let workbookPath = try target(offices[0], relativeTo: "")
        let workbook = try part(workbookPath)
        try require(workbook, name: "workbook", namespaces: spreadsheetNamespaces)
        let workbookRelationshipsPath = (workbookPath as NSString).deletingLastPathComponent
            + "/_rels/" + (workbookPath as NSString).lastPathComponent + ".rels"
        let relations = try relationships(try part(workbookRelationshipsPath.hasPrefix("/")
            ? String(workbookRelationshipsPath.dropFirst()) : workbookRelationshipsPath))
        let byID = Dictionary(uniqueKeysWithValues: relations.map { ($0.id, $0) })
        let sharedRelations = relations.filter { relationshipNamespaces.map { $0 + "/sharedStrings" }.contains($0.type) }
        guard sharedRelations.count <= 1 else { throw Failure.invalid("duplicate shared-string relationship") }
        var shared: [String] = []
        if let relation = sharedRelations.first {
            let strings = try part(target(relation, relativeTo: workbookPath))
            try require(strings, name: "sst", namespaces: spreadsheetNamespaces)
            let items = strings.children(named: "si")
            guard items.count <= maximumCells else { throw Failure.invalid("shared-string limit exceeded") }
            shared = try items.map { try stringValue($0) }
        }
        let sheets = workbook.children(named: "sheets").flatMap { $0.children(named: "sheet") }
        guard !sheets.isEmpty, sheets.count <= maximumSheets else { throw Failure.invalid("sheet count is unsupported") }
        var output = ""
        var cellCount = 0
        var seenSheetPaths: Set<String> = []
        for sheet in sheets {
            try checkCancellation()
            guard let name = sheet.attributes["name"], name.utf8.count <= 256,
                  let id = relationshipNamespaces.compactMap({ sheet.attributes[$0 + "|id"] }).first,
                  let relation = byID[id], relationshipNamespaces.map({ $0 + "/worksheet" }).contains(relation.type) else {
                throw Failure.invalid("sheet relationship is missing or unsupported")
            }
            let path = try target(relation, relativeTo: workbookPath)
            guard seenSheetPaths.insert(path).inserted else { throw Failure.invalid("duplicate worksheet target") }
            let worksheet = try part(path)
            try require(worksheet, name: "worksheet", namespaces: spreadsheetNamespaces)
            var lines: [String] = []
            var seenReferences: Set<String> = []
            let rows = worksheet.children(named: "sheetData").flatMap { $0.children(named: "row") }
            guard rows.count <= maximumCells else { throw Failure.invalid("row count limit exceeded") }
            for row in rows {
                for cell in row.children(named: "c") {
                    try checkCancellation()
                    cellCount += 1
                    guard cellCount <= maximumCells, let reference = cell.attributes["r"],
                          validCellReference(reference), seenReferences.insert(reference).inserted else {
                        throw Failure.invalid("cell count, reference or uniqueness is invalid")
                    }
                    let value = try cellValue(cell, shared: shared)
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("\(reference): \(value)")
                    }
                }
            }
            if !lines.isEmpty {
                let section = "[Sheet \(try decodeEscapes(name))]\n" + lines.joined(separator: "\n")
                guard section.utf8.count <= maximumTextBytes - output.utf8.count - (output.isEmpty ? 0 : 2) else {
                    throw Failure.invalid("extracted text byte limit exceeded")
                }
                if !output.isEmpty { output += "\n\n" }
                output += section
            }
        }
        return output
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
        return try root.children(named: "Relationship").map { node in
            guard let id = node.attributes["Id"], !id.isEmpty, ids.insert(id).inserted,
                  let type = node.attributes["Type"], let target = node.attributes["Target"] else {
                throw Failure.invalid("malformed or duplicate package relationship")
            }
            return Relationship(id: id, type: type, target: target,
                                external: node.attributes["TargetMode"] == "External")
        }
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

    private static func cellValue(_ cell: Element, shared: [String]) throws -> String {
        let values = cell.children(named: "v")
        let inline = cell.children(named: "is")
        let type = cell.attributes["t"] ?? "n"
        guard values.count <= 1, inline.count <= 1, cell.children(named: "f").count <= 1,
              values.allSatisfy({ $0.children.isEmpty }),
              type == "inlineStr" || inline.isEmpty else {
            throw Failure.invalid("multiple or incompatible cell value elements")
        }
        if !cell.children(named: "f").isEmpty, values.isEmpty {
            throw Failure.invalid("formula has no cached value; formulas are never evaluated")
        }
        let raw = values.first?.text ?? ""
        let value: String
        switch type {
        case "inlineStr":
            guard let inline = cell.children(named: "is").first, values.isEmpty else {
                throw Failure.invalid("invalid inline string cell")
            }
            value = try stringValue(inline)
        case "s":
            guard let index = Int(raw), index >= 0, index < shared.count else {
                throw Failure.invalid("shared-string index is invalid")
            }
            value = shared[index]
        case "b":
            guard raw == "0" || raw == "1" else { throw Failure.invalid("Boolean value is invalid") }
            value = raw == "1" ? "TRUE" : "FALSE"
        case "n":
            if !raw.isEmpty {
                guard let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else {
                    throw Failure.invalid("numeric value is invalid")
                }
            }
            value = raw
        case "d", "e", "str": value = try decodeEscapes(raw)
        default: throw Failure.invalid("unsupported cell value type")
        }
        guard value.utf8.count <= maximumCellBytes else { throw Failure.invalid("cell text byte limit exceeded") }
        return value
    }

    private static func stringValue(_ node: Element) throws -> String {
        // Phonetic annotation text (rPh) is not a cell's displayed string.
        let fragments = try node.children.flatMap { child -> [String] in
            guard child.namespace == node.namespace else { return [] }
            if child.name == "t" {
                guard child.children.isEmpty else { throw Failure.invalid("nested cell text elements") }
                return [try decodeEscapes(child.text)]
            }
            if child.name == "r" {
                return try child.children(named: "t").map {
                    guard $0.children.isEmpty else { throw Failure.invalid("nested cell text elements") }
                    return try decodeEscapes($0.text)
                }
            }
            return []
        }
        let result = fragments.joined()
        guard result.utf8.count <= maximumCellBytes else { throw Failure.invalid("string text byte limit exceeded") }
        return result
    }

    static func decodeEscapes(_ value: String) throws -> String {
        let input = Array(value.utf16)
        var units: [UInt16] = []
        var index = 0
        while index < input.count {
            if index + 7 <= input.count, input[index] == 95, input[index + 1] == 120, input[index + 6] == 95,
               let code = UInt16(String(decoding: input[(index + 2)..<(index + 6)], as: UTF16.self), radix: 16) {
                units.append(code); index += 7
            } else { units.append(input[index]); index += 1 }
        }
        index = 0
        while index < units.count {
            if (0xD800...0xDBFF).contains(units[index]) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    throw Failure.invalid("invalid escaped UTF-16")
                }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(units[index]) else { throw Failure.invalid("invalid escaped UTF-16") }
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func validCellReference(_ reference: String) -> Bool {
        let bytes = Array(reference.utf8)
        guard bytes.count <= 10 else { return false }
        var index = 0, column = 0
        while index < bytes.count, (65...90).contains(bytes[index]) {
            column = column * 26 + Int(bytes[index] - 64); index += 1
        }
        guard index > 0, column <= 16_384, index < bytes.count, bytes[index] != 48,
              bytes[index...].allSatisfy({ (48...57).contains($0) }),
              let row = Int(String(decoding: bytes[index...], as: UTF8.self)) else { return false }
        return (1...1_048_576).contains(row)
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
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
        func children(named name: String) -> [Element] {
            children.filter { $0.name == name && $0.namespace == namespace }
        }
    }

    private static func parse(_ data: Data) throws -> Element {
        guard data.count <= maximumPartBytes, let text = String(data: data, encoding: .utf8),
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
        return root
    }

    private static func containsNoDeclarations(_ text: String) throws -> Bool {
        var cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: "<") {
            let suffix = text[start...]
            let endMarker: String?
            if suffix.hasPrefix("<!--") { endMarker = "-->" }
            else if suffix.hasPrefix("<![CDATA[") { endMarker = "]]>" }
            else if suffix.hasPrefix("<?") { endMarker = "?>" }
            else { endMarker = nil }
            if let endMarker {
                guard let end = text.range(of: endMarker, range: start..<text.endIndex) else {
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
        private var count = 0
        private var textBytes = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 32_768, stack.count < 32, !Task.isCancelled else {
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
                normalized[namespace.isEmpty ? local : namespace + "|" + local] = value
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

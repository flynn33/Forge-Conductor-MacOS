import Foundation

/// Bounded ODF 1.3 cell-text conversion. Cached values are read, never evaluated;
/// styles, annotations and external data are not instruction text.
enum NativeODSReader {
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let detail): "The spreadsheet could not be converted: \(detail)" }
        }
    }

    static let maximumContainerBytes = 16 * 1_048_576
    static let maximumParts = 256
    static let maximumPartBytes = 2 * 1_048_576
    static let maximumExpandedBytes = 8 * 1_048_576
    static let maximumSheets = 16
    static let maximumPhysicalCells = 4_352
    static let maximumValueCells = 4_096
    static let maximumCellBytes = 4_096
    static let maximumTextBytes = 128 * 1_024
    static let maximumXMLNodes = 32_768
    static let maximumXMLDepth = 32
    private static let maximumRows = 1_048_576
    private static let maximumColumns = 16_384
    private static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    private static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private static let manifest = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    private static let mediaType = "application/vnd.oasis.opendocument.spreadsheet"

    static func text(in data: Data) throws -> String {
        try checkCancellation()
        guard !Thread.isMainThread else { throw Failure.invalid("conversion requires a worker thread") }
        guard data.count <= maximumContainerBytes else { throw Failure.invalid("container byte limit exceeded") }
        let entries = try SafeZIPArchive.inspect(data)
        guard entries.count <= maximumParts,
              entries.allSatisfy({ $0.uncompressedBytes <= maximumPartBytes }),
              entries.reduce(0, { $0 + $1.uncompressedBytes }) <= maximumExpandedBytes else {
            throw Failure.invalid("part or expanded-byte limit exceeded")
        }
        guard data.count >= 38 + mediaType.utf8.count,
              data.subdata(in: 8..<10) == Data([0, 0]),
              data.subdata(in: 26..<30) == Data([8, 0, 0, 0]),
              data.subdata(in: 30..<38) == Data("mimetype".utf8),
              data.subdata(in: 38..<(38 + mediaType.utf8.count)) == Data(mediaType.utf8) else {
            throw Failure.invalid("the first package entry must be the stored spreadsheet MIME type")
        }
        let available = Set(entries.filter { !$0.isDirectory }.map(\.path))
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("forge-ods-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try SafeZIPArchive.extract(data, to: stage, expected: entries)
        func bytes(_ path: String) throws -> Data {
            try checkCancellation()
            guard available.contains(path) else { throw Failure.invalid("a required package part is missing") }
            let value = try Data(contentsOf: stage.appendingPathComponent(path))
            guard value.count <= maximumPartBytes else { throw Failure.invalid("part byte limit exceeded") }
            return value
        }
        guard try bytes("mimetype") == Data(mediaType.utf8) else { throw Failure.invalid("unsupported MIME type") }
        let package = try parse(bytes("META-INF/manifest.xml"))
        guard package.isNamed("manifest", namespace: manifest), package.attribute("version", namespace: manifest) == "1.3" else {
            throw Failure.invalid("unsupported manifest namespace or version")
        }
        let files = package.children(named: "file-entry", namespace: manifest)
        var seenPaths: Set<String> = []
        for file in files {
            guard let path = file.attribute("full-path", namespace: manifest), seenPaths.insert(path).inserted,
                  file.children.isEmpty else { throw Failure.invalid("duplicate, encrypted or unsupported manifest entry") }
        }
        guard let rootEntry = files.first(where: { $0.attribute("full-path", namespace: manifest) == "/" }),
              rootEntry.attribute("media-type", namespace: manifest) == mediaType,
              let contentEntry = files.first(where: { $0.attribute("full-path", namespace: manifest) == "content.xml" }),
              contentEntry.attribute("media-type", namespace: manifest) == "text/xml" else {
            throw Failure.invalid("spreadsheet/content manifest entries are missing")
        }
        let document = try parse(bytes("content.xml"))
        guard document.isNamed("document-content", namespace: office), document.attribute("version", namespace: office) == "1.3" else {
            throw Failure.invalid("unsupported content root or version")
        }
        let bodies = document.children(named: "body", namespace: office)
        guard bodies.count == 1 else { throw Failure.invalid("exactly one document body is required") }
        let spreadsheets = bodies[0].children(named: "spreadsheet", namespace: office)
        guard spreadsheets.count == 1 else { throw Failure.invalid("exactly one spreadsheet body is required") }
        let sheets = spreadsheets[0].children(named: "table", namespace: table)
        guard !sheets.isEmpty, sheets.count <= maximumSheets else { throw Failure.invalid("sheet count is unsupported") }
        var output = "", outputBytes = 0, physicalCells = 0, emittedCells = 0
        var sheetNames: Set<String> = []
        for sheet in sheets {
            try checkCancellation()
            guard let name = sheet.attribute("name", namespace: table), !name.isEmpty,
                  name.utf8.count <= 256, sheetNames.insert(name).inserted else { throw Failure.invalid("sheet name is invalid or duplicated") }
            var rows: [Element] = []
            try collectRows(sheet, into: &rows)
            guard !rows.isEmpty else { throw Failure.invalid("a sheet must contain a row") }
            var rowNumber = 1, section = "", sectionBytes = 0
            for row in rows {
                try checkCancellation()
                let rowRepeat = try positive(row.attribute("number-rows-repeated", namespace: table), maximum: maximumPhysicalCells)
                guard rowRepeat <= maximumRows - rowNumber + 1 else { throw Failure.invalid("row coordinate limit exceeded") }
                var column = 1, rowCells = 0, values: [(Int, String)] = []
                for cell in row.children where cell.namespace == table && ["table-cell", "covered-table-cell"].contains(cell.name) {
                    try checkCancellation()
                    let count = try positive(cell.attribute("number-columns-repeated", namespace: table), maximum: maximumPhysicalCells)
                    guard count <= maximumPhysicalCells - rowCells else { throw Failure.invalid("expanded physical cell limit exceeded") }
                    rowCells += count
                    guard count <= maximumColumns - column + 1,
                          try positive(cell.attribute("number-columns-spanned", namespace: table), maximum: maximumColumns) == 1,
                          try positive(cell.attribute("number-rows-spanned", namespace: table), maximum: maximumRows) == 1 else {
                        throw Failure.invalid("cell coordinate or unsupported merge")
                    }
                    let value = try cellValue(cell)
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard count <= maximumValueCells - values.count else { throw Failure.invalid("repeated cell limit exceeded") }
                        for offset in 0..<count { values.append((column + offset, value)) }
                    }
                    column += count
                }
                guard rowCells > 0, rowCells <= (maximumPhysicalCells - physicalCells) / rowRepeat else { throw Failure.invalid("expanded physical cell limit exceeded") }
                physicalCells += rowCells * rowRepeat
                guard values.count <= (maximumValueCells - emittedCells) / rowRepeat else { throw Failure.invalid("repeated value-cell limit exceeded") }
                emittedCells += values.count * rowRepeat
                if !values.isEmpty {
                    for repeatedRow in 0..<rowRepeat {
                        try checkCancellation()
                        for (column, value) in values {
                            let prefix = section.isEmpty ? "[Sheet \(name)]\n" : "\n"
                            let line = "\(columnName(column))\(rowNumber + repeatedRow): \(value)"
                            let addition = prefix.utf8.count + line.utf8.count
                            guard addition <= maximumTextBytes - outputBytes - sectionBytes - (output.isEmpty ? 0 : 2) else {
                                throw Failure.invalid("extracted text byte limit exceeded")
                            }
                            section += prefix + line; sectionBytes += addition
                        }
                    }
                }
                rowNumber += rowRepeat
            }
            if !section.isEmpty {
                if !output.isEmpty { output += "\n\n"; outputBytes += 2 }
                output += section; outputBytes += sectionBytes
            }
        }
        return output
    }

    private static func collectRows(_ node: Element, into rows: inout [Element]) throws {
        for child in node.children where child.namespace == table {
            try checkCancellation()
            if child.name == "table-row" {
                guard rows.count < maximumPhysicalCells else { throw Failure.invalid("physical row limit exceeded") }
                rows.append(child)
            } else if ["table-row-group", "table-header-rows", "table-rows"].contains(child.name) {
                try collectRows(child, into: &rows)
            }
        }
    }

    private static func cellValue(_ cell: Element) throws -> String {
        guard !cell.children.contains(where: { $0.namespace == text && !["p", "h"].contains($0.name) }) else {
            throw Failure.invalid("unsupported cell text block")
        }
        let paragraphs = cell.children.filter { $0.namespace == text && ["p", "h"].contains($0.name) }
        let kind = cell.attribute("value-type", namespace: office)
        let hasCachedValue = ["value", "string-value", "boolean-value", "date-value", "time-value"].contains { cell.attribute($0, namespace: office) != nil }
        guard cell.name != "covered-table-cell" || (paragraphs.isEmpty && kind == nil && !hasCachedValue && cell.attribute("formula", namespace: table) == nil),
              !cell.children.contains(where: { $0.namespace == table && $0.name == "table" }) else {
            throw Failure.invalid("covered or nested cell text is unsupported")
        }
        if let kind {
            guard ["string", "float", "percentage", "currency", "boolean", "date", "time"].contains(kind) else { throw Failure.invalid("unsupported cell value type") }
        }
        let value: String
        if !paragraphs.isEmpty {
            var result = ""
            for (index, paragraph) in paragraphs.enumerated() {
                let fragment = try paragraphText(paragraph)
                guard fragment.utf8.count <= maximumCellBytes - result.utf8.count - (index == 0 ? 0 : 1) else { throw Failure.invalid("cell text byte limit exceeded") }
                if index > 0 { result += "\n" }
                result += fragment
            }
            value = result
        } else {
            switch kind {
            case nil: value = ""
            case "string": value = cell.attribute("string-value", namespace: office) ?? ""
            case "float", "percentage", "currency":
                guard let cached = cell.attribute("value", namespace: office), cached.utf8.count <= maximumCellBytes,
                      let number = Double(cached), number.isFinite else { throw Failure.invalid("numeric cached value is missing or invalid") }
                value = cached
            case "boolean":
                guard let cached = cell.attribute("boolean-value", namespace: office), ["true", "false", "1", "0"].contains(cached) else { throw Failure.invalid("Boolean cached value is missing or invalid") }
                value = ["true", "1"].contains(cached) ? "TRUE" : "FALSE"
            case "date", "time":
                guard let cached = cell.attribute(kind == "date" ? "date-value" : "time-value", namespace: office), !cached.isEmpty else { throw Failure.invalid("cached scalar value is missing") }
                value = cached
            default: throw Failure.invalid("unsupported cell value type")
            }
        }
        guard value.utf8.count <= maximumCellBytes else { throw Failure.invalid("cell text byte limit exceeded") }
        if cell.attribute("formula", namespace: table) != nil, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.invalid("formula has no recoverable cached value; formulas are never evaluated")
        }
        return value
    }

    private enum Token { case raw(String), explicit(String) }
    private static func paragraphText(_ paragraph: Element) throws -> String {
        var tokens: [Token] = [], explicitBytes = 0
        func flatten(_ node: Element) throws {
            try checkCancellation()
            for content in node.contents {
                switch content {
                case .characters(let value):
                    if case .raw(let previous)? = tokens.last { tokens[tokens.count - 1] = .raw(previous + value) }
                    else { tokens.append(.raw(value)) }
                case .element(let child):
                    guard child.namespace == text else { throw Failure.invalid("unsupported paragraph text namespace") }
                    switch child.name {
                    case "span", "a": try flatten(child)
                    case "s":
                        let count = try positive(child.attribute("c", namespace: text), maximum: maximumCellBytes)
                        guard child.children.isEmpty, child.directText.isEmpty else { throw Failure.invalid("invalid explicit space") }
                        guard count <= maximumCellBytes - explicitBytes else { throw Failure.invalid("explicit whitespace byte limit exceeded") }
                        explicitBytes += count
                        tokens.append(.explicit(String(repeating: " ", count: count)))
                    case "tab", "line-break":
                        guard child.children.isEmpty, child.directText.isEmpty else { throw Failure.invalid("invalid whitespace marker") }
                        guard explicitBytes < maximumCellBytes else { throw Failure.invalid("explicit whitespace byte limit exceeded") }
                        explicitBytes += 1
                        tokens.append(.explicit(child.name == "tab" ? "\t" : "\n"))
                    default: throw Failure.invalid("unsupported paragraph text element")
                    }
                }
            }
        }
        try flatten(paragraph)
        var result = "", resultBytes = 0
        for (index, token) in tokens.enumerated() {
            let fragment: String
            switch token {
            case .explicit(let value): fragment = value
            case .raw(let value):
                var collapsed = "", lastSpace = false
                for scalar in value.unicodeScalars {
                    let space = [UInt32(9), 10, 13, 32].contains(scalar.value)
                    if space { if !lastSpace { collapsed.append(" ") }; lastSpace = true }
                    else { collapsed.unicodeScalars.append(scalar); lastSpace = false }
                }
                if index == 0, collapsed.hasPrefix(" ") { collapsed.removeFirst() }
                if index == tokens.count - 1, collapsed.hasSuffix(" ") { collapsed.removeLast() }
                fragment = collapsed
            }
            guard fragment.utf8.count <= maximumCellBytes - resultBytes else { throw Failure.invalid("paragraph text byte limit exceeded") }
            result += fragment; resultBytes += fragment.utf8.count
        }
        return result
    }

    private static func positive(_ value: String?, maximum: Int) throws -> Int {
        guard let value else { return 1 }
        guard !value.isEmpty, value.utf8.count <= 10, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(value), (1...maximum).contains(count) else { throw Failure.invalid("repeat/count is invalid or exceeds its limit") }
        return count
    }
    private static func columnName(_ value: Int) -> String {
        var number = value, bytes: [UInt8] = []
        while number > 0 { number -= 1; bytes.append(UInt8(65 + number % 26)); number /= 26 }
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }
    private static func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }

    private final class Element {
        enum Content { case characters(String), element(Element) }
        let name: String, namespace: String, attributes: [String: String]
        var contents: [Content] = []
        var children: [Element] { contents.compactMap { if case .element(let node) = $0 { node } else { nil } } }
        var directText: String { contents.compactMap { if case .characters(let value) = $0 { value } else { nil } }.joined() }
        init(name: String, namespace: String, attributes: [String: String]) { self.name = name; self.namespace = namespace; self.attributes = attributes }
        func isNamed(_ name: String, namespace: String) -> Bool { self.name == name && self.namespace == namespace }
        func attribute(_ name: String, namespace: String) -> String? { attributes[namespace + "|" + name] }
        func children(named name: String, namespace: String) -> [Element] { children.filter { $0.isNamed(name, namespace: namespace) } }
    }
    private static func parse(_ data: Data) throws -> Element {
        try checkCancellation()
        guard data.count <= maximumPartBytes, let value = String(data: data, encoding: .utf8),
              hasUTF8Declaration(value), try containsNoDeclarations(value) else { throw Failure.invalid("XML must be bounded UTF8 without DTD/entity declarations") }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never
        let delegate = Parser(); parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.error { throw error }
        guard parsed, let root = delegate.root, delegate.stack.isEmpty else { throw Failure.invalid("malformed XML") }
        try checkCancellation()
        return root
    }
    private static func hasUTF8Declaration(_ value: String) -> Bool {
        let body = value.first == "\u{FEFF}" ? value.dropFirst() : value[...]
        guard body.hasPrefix("<?xml"), body.count > 5, " \t\r\n".contains(body[body.index(body.startIndex, offsetBy: 5)]) else { return true }
        guard let end = body.range(of: "?>") else { return false }
        let declaration = body[..<end.lowerBound]
        guard let encoding = declaration.range(of: #"\bencoding[ \t\r\n]*=[ \t\r\n]*(['"])([^'"]+)\1"#, options: .regularExpression) else { return true }
        let assignment = declaration[encoding]
        guard let quote = assignment.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return false }
        return assignment[assignment.index(after: quote)..<assignment.index(before: assignment.endIndex)].lowercased() == "utf-8"
    }
    private static func containsNoDeclarations(_ value: String) throws -> Bool {
        var cursor = value.startIndex
        while let start = value[cursor...].firstIndex(of: "<") {
            try checkCancellation()
            let suffix = value[start...]
            let marker: String?
            if suffix.hasPrefix("<!--") { marker = "-->" }
            else if suffix.hasPrefix("<![CDATA[") { marker = "]]>" }
            else if suffix.hasPrefix("<?") { marker = "?>" }
            else { marker = nil }
            if let marker {
                guard let end = value.range(of: marker, range: start..<value.endIndex) else { throw Failure.invalid("unterminated XML comment/CDATA/instruction") }
                cursor = end.upperBound
            } else {
                if suffix.hasPrefix("<!DOCTYPE") || suffix.hasPrefix("<!ENTITY") { return false }
                cursor = value.index(after: start)
            }
        }
        return true
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var root: Element?, error: Error?
        var stack: [(element: Element, prefixes: [String: String])] = []
        private var count = 0, textBytes = 0, segments = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= maximumXMLNodes, stack.count < maximumXMLDepth, !Task.isCancelled else { error = Task.isCancelled ? CancellationError() : Failure.invalid("XML node/depth limit exceeded"); parser.abortParsing(); return }
            var prefixes = stack.last?.prefixes ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
            for (key, value) in attributes {
                if key == "xmlns" { prefixes[""] = value }
                else if key.hasPrefix("xmlns:") { prefixes[String(key.dropFirst(6))] = value }
            }
            func expanded(_ name: String, attribute: Bool) -> (String, String) {
                let pieces = name.split(separator: ":", maxSplits: 1).map(String.init)
                return pieces.count == 2 ? (pieces[1], prefixes[pieces[0]] ?? "") : (name, attribute ? "" : prefixes[""] ?? "")
            }
            let (local, namespace) = expanded(name, attribute: false)
            var normalized: [String: String] = [:]
            for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
                let (local, namespace) = expanded(key, attribute: true)
                let expandedName = namespace.isEmpty ? local : namespace + "|" + local
                guard normalized.updateValue(value, forKey: expandedName) == nil else { error = Failure.invalid("duplicate expanded XML attribute"); parser.abortParsing(); return }
            }
            let node = Element(name: local, namespace: namespace, attributes: normalized)
            if let parent = stack.last?.element { parent.contents.append(.element(node)) }
            else if root == nil { root = node }
            else { error = Failure.invalid("multiple XML roots"); parser.abortParsing(); return }
            stack.append((node, prefixes))
        }
        func parser(_ parser: XMLParser, foundCharacters value: String) {
            textBytes += value.utf8.count
            guard textBytes <= maximumPartBytes, !Task.isCancelled else { error = Task.isCancelled ? CancellationError() : Failure.invalid("XML text limit exceeded"); parser.abortParsing(); return }
            guard let node = stack.last?.element else { return }
            if case .characters(let previous)? = node.contents.last { node.contents[node.contents.count - 1] = .characters(previous + value) }
            else {
                segments += 1
                guard segments <= maximumXMLNodes * 2 else { error = Failure.invalid("XML mixed-content segment limit exceeded"); parser.abortParsing(); return }
                node.contents.append(.characters(value))
            }
        }
        func parser(_ parser: XMLParser, foundCDATA value: Data) {
            guard let text = String(data: value, encoding: .utf8) else { error = Failure.invalid("invalid CDATA"); parser.abortParsing(); return }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
    }
}

import Foundation

enum NativeODSError: Error, Equatable, LocalizedError {
    case workerRequired, invalidRows, contentTooLarge, invalidText, outputTooLarge, structureTooLarge

    var code: String {
        switch self {
        case .workerRequired: "ods_worker_required"
        case .invalidRows: "invalid_rows"
        case .contentTooLarge: "content_too_large"
        case .invalidText: "invalid_text"
        case .outputTooLarge: "ods_output_too_large"
        case .structureTooLarge: "ods_structure_too_large"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "ODS encoding requires a worker thread"
        case .invalidRows: "rows must contain arrays of strings"
        case .contentTooLarge: "ODS text is limited to 256 rows, 64 columns, 4096 cells, 4096 UTF-8 bytes per cell, and 65536 total text bytes"
        case .invalidText: "ODS text contains a character disallowed by XML 1.0"
        case .outputTooLarge: "Encoded ODS is limited to 1048576 bytes"
        case .structureTooLarge: "ODS content is limited to 32768 XML elements"
        }
    }
}

/// One call-local ODF text worksheet and three fixed, stored ZIP parts.
enum NativeODSWriter {
    static let maximumRows = 256
    static let maximumColumns = 64
    static let maximumCells = 4096
    static let maximumCellBytes = 4096
    static let maximumTextBytes = 65_536
    static let maximumOutputBytes = 1_048_576
    static let maximumXMLNodes = NativeODSReader.maximumXMLNodes
    static let textContract = "ods-text-cells-v1"
    static let mediaType = "application/vnd.oasis.opendocument.spreadsheet"

    static func rows(from value: Any?) throws -> [[String]] {
        guard let rawRows = value as? [Any] else { throw NativeODSError.invalidRows }
        guard rawRows.count <= maximumRows else { throw NativeODSError.contentTooLarge }
        var rows: [[String]] = []
        var cells = 0
        for rawRow in rawRows {
            guard let row = rawRow as? [Any] else { throw NativeODSError.invalidRows }
            guard row.count <= maximumColumns, cells <= maximumCells - row.count else {
                throw NativeODSError.contentTooLarge
            }
            guard row.allSatisfy({ $0 is String }) else { throw NativeODSError.invalidRows }
            rows.append(row.map { $0 as! String })
            cells += row.count
        }
        return rows
    }

    static func encode(rows: [[String]], cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> Data {
        guard !Thread.isMainThread else { throw NativeODSError.workerRequired }
        try cancellation?.checkCancellation()
        try validate(rows, cancellation: cancellation)
        guard outputByteLimit > 0, outputByteLimit <= maximumOutputBytes else {
            throw NativeODSError.outputTooLarge
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        var content = BoundedBytes(limit: outputByteLimit)
        try content.append(header + "<office:document-content xmlns:office=\"\(office)\" xmlns:table=\"\(table)\" xmlns:text=\"\(text)\" office:version=\"1.3\"><office:body><office:spreadsheet><table:table table:name=\"Sheet1\">")
        let columns = max(1, rows.map(\.count).max() ?? 0)
        try content.append("<table:table-column table:number-columns-repeated=\"\(columns)\"/>")
        var nodes = 5
        // ODF's schema requires at least one row, and at least one cell per row.
        // Structural blank padding does not alter the input row/cell metadata.
        let physicalRows = rows.isEmpty ? [[]] : rows
        for row in physicalRows {
            try cancellation?.checkCancellation()
            try element("<table:table-row>", to: &content, nodes: &nodes)
            for value in row.isEmpty ? [""] : row {
                try cancellation?.checkCancellation()
                try element("<table:table-cell office:value-type=\"string\">", to: &content, nodes: &nodes)
                try element("<text:p>", to: &content, nodes: &nodes)
                try appendText(value, to: &content, nodes: &nodes, cancellation: cancellation)
                try content.append("</text:p></table:table-cell>")
            }
            try content.append("</table:table-row>")
        }
        try content.append("</table:table></office:spreadsheet></office:body></office:document-content>")
        let manifest = header + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"\(mediaType)\" manifest:version=\"1.3\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        let parts: [(String, Data)] = [
            ("mimetype", Data(mediaType.utf8)),
            ("content.xml", content.data),
            ("META-INF/manifest.xml", Data(manifest.utf8)),
        ]
        var zip = BoundedBytes(limit: outputByteLimit)
        var directory = BoundedBytes(limit: outputByteLimit)
        for (name, bytes) in parts {
            try cancellation?.checkCancellation()
            let offset = UInt32(zip.data.count)
            let checksum = try crc32(bytes, cancellation: cancellation)
            let size = UInt32(bytes.count)
            let nameBytes = Array(name.utf8)
            try zip.append32(0x04034b50)
            for value in [20, 0x0800, 0, 0, 0x0021] as [UInt16] { try zip.append16(value) }
            for value in [checksum, size, size] { try zip.append32(value) }
            try zip.append16(UInt16(nameBytes.count)); try zip.append16(0)
            try zip.append(nameBytes); try zip.append(bytes)
            try directory.append32(0x02014b50)
            for value in [20, 20, 0x0800, 0, 0, 0x0021] as [UInt16] { try directory.append16(value) }
            for value in [checksum, size, size] { try directory.append32(value) }
            for value in [UInt16(nameBytes.count), 0, 0, 0, 0] { try directory.append16(value) }
            try directory.append32(0); try directory.append32(offset)
            try directory.append(nameBytes)
        }
        try cancellation?.checkCancellation()
        let directoryOffset = UInt32(zip.data.count)
        try zip.append(directory.data)
        try zip.append32(0x06054b50)
        for value in [0, 0, 3, 3] as [UInt16] { try zip.append16(value) }
        try zip.append32(UInt32(directory.data.count)); try zip.append32(directoryOffset)
        try zip.append16(0)
        try cancellation?.checkCancellation()
        return zip.data
    }

    private static func validate(_ rows: [[String]], cancellation: ToolCallCancellation?) throws {
        guard rows.count <= maximumRows else { throw NativeODSError.contentTooLarge }
        var cells = 0, total = 0
        for row in rows {
            try cancellation?.checkCancellation()
            guard row.count <= maximumColumns, cells <= maximumCells - row.count else {
                throw NativeODSError.contentTooLarge
            }
            cells += row.count
            for value in row {
                try cancellation?.checkCancellation()
                let count = value.utf8.prefix(maximumCellBytes + 1).count
                guard count <= maximumCellBytes, total <= maximumTextBytes - count else {
                    throw NativeODSError.contentTooLarge
                }
                total += count
                for (index, scalar) in value.unicodeScalars.enumerated() {
                    if index % 256 == 0 { try cancellation?.checkCancellation() }
                    let code = scalar.value
                    guard code == 9 || code == 10 || code == 13
                            || (0x20...0xD7FF).contains(code) || (0xE000...0xFFFD).contains(code)
                            || (0x10000...0x10FFFF).contains(code) else { throw NativeODSError.invalidText }
                }
            }
        }
    }

    private static func element(_ xml: String, to output: inout BoundedBytes, nodes: inout Int) throws {
        guard nodes < maximumXMLNodes else { throw NativeODSError.structureTooLarge }
        nodes += 1
        try output.append(xml)
    }

    private static func appendText(_ value: String, to output: inout BoundedBytes,
                                   nodes: inout Int, cancellation: ToolCallCancellation?) throws {
        let scalars = value.unicodeScalars
        var index = scalars.startIndex, visited = 0
        while index < scalars.endIndex {
            if visited % 256 == 0 { try cancellation?.checkCancellation() }
            let scalar = scalars[index]
            var next = scalars.index(after: index)
            switch scalar.value {
            case 32:
                var spaces = 1
                while next < scalars.endIndex, scalars[next].value == 32 {
                    next = scalars.index(after: next); spaces += 1
                    if spaces % 256 == 0 { try cancellation?.checkCancellation() }
                }
                try element("<text:s text:c=\"\(spaces)\"/>", to: &output, nodes: &nodes)
                visited += spaces - 1
            case 9: try element("<text:tab/>", to: &output, nodes: &nodes)
            case 10: try element("<text:line-break/>", to: &output, nodes: &nodes)
            case 13:
                if next < scalars.endIndex, scalars[next].value == 10 {
                    next = scalars.index(after: next); visited += 1
                }
                try element("<text:line-break/>", to: &output, nodes: &nodes)
            case 38: try output.append("&amp;")
            case 60: try output.append("&lt;")
            case 62: try output.append("&gt;")
            default: try output.append(String(scalar))
            }
            index = next; visited += 1
        }
    }

    private static func crc32(_ bytes: Data, cancellation: ToolCallCancellation?) throws -> UInt32 {
        var checksum: UInt32 = 0xFFFFFFFF
        for (index, byte) in bytes.enumerated() {
            if index % 4096 == 0 { try cancellation?.checkCancellation() }
            checksum ^= UInt32(byte)
            for _ in 0..<8 { checksum = (checksum >> 1) ^ ((checksum & 1) == 1 ? 0xEDB88320 : 0) }
        }
        return checksum ^ 0xFFFFFFFF
    }

    private struct BoundedBytes {
        let limit: Int
        private(set) var data = Data()
        mutating func append(_ text: String) throws { try append(text.utf8) }
        mutating func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
            guard bytes.count <= limit - data.count else { throw NativeODSError.outputTooLarge }
            data.append(contentsOf: bytes)
        }
        mutating func append16(_ value: UInt16) throws {
            try append([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
        }
        mutating func append32(_ value: UInt32) throws {
            try append([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
        }
    }
}

import Foundation

enum NativeXLSXError: Error, Equatable, LocalizedError {
    case workerRequired, invalidRows, contentTooLarge, invalidText, outputTooLarge

    var code: String {
        switch self {
        case .workerRequired: "xlsx_worker_required"
        case .invalidRows: "invalid_rows"
        case .contentTooLarge: "content_too_large"
        case .invalidText: "invalid_text"
        case .outputTooLarge: "xlsx_output_too_large"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "XLSX encoding requires a worker thread"
        case .invalidRows: "rows must contain arrays of strings"
        case .contentTooLarge: "XLSX text is limited to 256 rows, 64 columns, 4096 cells, 4096 UTF-8 bytes per cell, and 65536 total text bytes"
        case .invalidText: "XLSX text contains a character disallowed by XML 1.0"
        case .outputTooLarge: "Encoded XLSX is limited to 1048576 bytes"
        }
    }
}

/// Call-local, finite SpreadsheetML text cells and five fixed stored ZIP parts.
enum NativeXLSXWriter {
    static let maximumRows = 256
    static let maximumColumns = 64
    static let maximumCells = 4096
    static let maximumCellBytes = 4096
    static let maximumTextBytes = 65_536
    static let maximumOutputBytes = 1_048_576
    static let textContract = "xlsx-text-cells-v1"

    static func rows(from value: Any?) throws -> [[String]] {
        guard let rawRows = value as? [Any] else { throw NativeXLSXError.invalidRows }
        guard rawRows.count <= maximumRows else { throw NativeXLSXError.contentTooLarge }
        var rows: [[String]] = []
        var cells = 0
        for rawRow in rawRows {
            guard let row = rawRow as? [Any] else { throw NativeXLSXError.invalidRows }
            guard row.count <= maximumColumns, cells <= maximumCells - row.count else {
                throw NativeXLSXError.contentTooLarge
            }
            guard row.allSatisfy({ $0 is String }) else { throw NativeXLSXError.invalidRows }
            rows.append(row.map { $0 as! String })
            cells += row.count
        }
        return rows
    }

    static func encode(rows: [[String]], cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> Data {
        guard !Thread.isMainThread else { throw NativeXLSXError.workerRequired }
        try cancellation?.checkCancellation()
        try validate(rows, cancellation: cancellation)
        guard outputByteLimit > 0, outputByteLimit <= maximumOutputBytes else {
            throw NativeXLSXError.outputTooLarge
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var worksheet = BoundedBytes(limit: outputByteLimit)
        try worksheet.append(header + "<worksheet xmlns=\"\(spreadsheet)\"><sheetData>")
        for (rowIndex, row) in rows.enumerated() {
            try cancellation?.checkCancellation()
            try worksheet.append("<row r=\"\(rowIndex + 1)\">")
            for (column, text) in row.enumerated() {
                try cancellation?.checkCancellation()
                try worksheet.append("<c r=\"\(columnName(column))\(rowIndex + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">")
                try appendText(text, to: &worksheet)
                try worksheet.append("</t></is></c>")
            }
            try worksheet.append("</row>")
        }
        try worksheet.append("</sheetData></worksheet>")
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data((header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>").utf8)),
            ("_rels/.rels", Data((header + "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(officeRelationships)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>").utf8)),
            ("xl/workbook.xml", Data((header + "<workbook xmlns=\"\(spreadsheet)\" xmlns:r=\"\(officeRelationships)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>").utf8)),
            ("xl/_rels/workbook.xml.rels", Data((header + "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(officeRelationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>").utf8)),
            ("xl/worksheets/sheet1.xml", worksheet.data),
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
        for value in [0, 0, 5, 5] as [UInt16] { try zip.append16(value) }
        try zip.append32(UInt32(directory.data.count)); try zip.append32(directoryOffset)
        try zip.append16(0)
        try cancellation?.checkCancellation()
        return zip.data
    }

    private static func validate(_ rows: [[String]], cancellation: ToolCallCancellation?) throws {
        guard rows.count <= maximumRows else { throw NativeXLSXError.contentTooLarge }
        var cells = 0
        var total = 0
        for row in rows {
            try cancellation?.checkCancellation()
            guard row.count <= maximumColumns, cells <= maximumCells - row.count else {
                throw NativeXLSXError.contentTooLarge
            }
            cells += row.count
            for text in row {
                try cancellation?.checkCancellation()
                let count = text.utf8.prefix(maximumCellBytes + 1).count
                guard count <= maximumCellBytes, total <= maximumTextBytes - count else {
                    throw NativeXLSXError.contentTooLarge
                }
                total += count
                guard text.unicodeScalars.allSatisfy({ scalar in
                    let value = scalar.value
                    return value == 9 || value == 10 || value == 13
                        || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value)
                        || (0x10000...0x10FFFF).contains(value)
                }) else { throw NativeXLSXError.invalidText }
            }
        }
    }

    private static func columnName(_ column: Int) -> String {
        let number = column + 1
        if number <= 26 { return String(UnicodeScalar(64 + number)!) }
        return String(UnicodeScalar(64 + (number - 1) / 26)!)
            + String(UnicodeScalar(65 + (number - 1) % 26)!)
    }

    private static func appendText(_ text: String, to output: inout BoundedBytes) throws {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            switch scalar.value {
            case 38: try output.append("&amp;")
            case 60: try output.append("&lt;")
            case 62: try output.append("&gt;")
            case 13: try output.append("_x000D_")
            case 95 where resemblesEscape(in: scalars, at: index): try output.append("_x005F_")
            default: try output.append(String(scalar))
            }
            index = scalars.index(after: index)
        }
    }

    private static func resemblesEscape(in scalars: String.UnicodeScalarView,
                                        at start: String.UnicodeScalarView.Index) -> Bool {
        var iterator = scalars[start...].makeIterator()
        guard iterator.next()?.value == 95, let prefix = iterator.next()?.value,
              prefix == 120 || prefix == 88 else { return false }
        for _ in 0..<4 {
            guard let value = iterator.next()?.value,
                  (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) else {
                return false
            }
        }
        return iterator.next()?.value == 95
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
            guard bytes.count <= limit - data.count else { throw NativeXLSXError.outputTooLarge }
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

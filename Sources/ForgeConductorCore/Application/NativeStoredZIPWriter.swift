import Foundation

enum NativeStoredZIPError: Error, Equatable, LocalizedError {
    case workerRequired, invalidEntries, entryLimit, invalidEntry, invalidName
    case nameLimit, componentLimit, nonNFCName, nameCollision, invalidBase64
    case base64Limit, inputLimit, outputLimit, internalMismatch

    var code: String {
        switch self {
        case .workerRequired: "archive_worker_required"
        case .invalidEntries: "invalid_archive_entries"
        case .entryLimit: "archive_entry_limit"
        case .invalidEntry: "invalid_archive_entry"
        case .invalidName: "invalid_archive_name"
        case .nameLimit: "archive_name_too_large"
        case .componentLimit: "archive_component_too_large"
        case .nonNFCName: "archive_name_not_nfc"
        case .nameCollision: "archive_name_collision"
        case .invalidBase64: "invalid_archive_base64"
        case .base64Limit: "archive_base64_too_large"
        case .inputLimit: "archive_input_too_large"
        case .outputLimit: "archive_output_too_large"
        case .internalMismatch: "archive_encode_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "ZIP encoding requires a worker thread"
        case .invalidEntries: "entries must be an array"
        case .entryLimit: "ZIP archives are limited to 32 supplied files"
        case .invalidEntry: "Each entry must contain only string name and content fields"
        case .invalidName: "Entry names must be relative file paths without absolute, drive, backslash, control, dot or empty components"
        case .nameLimit: "Entry names are limited to 1024 UTF-8 bytes"
        case .componentLimit: "Each entry name component is limited to 255 UTF-8 bytes"
        case .nonNFCName: "Entry names must already be Unicode NFC"
        case .nameCollision: "Duplicate, case-insensitive or ancestor-file name conflicts are not allowed"
        case .invalidBase64: "Entry content must be canonical padded base64"
        case .base64Limit: "Each base64 entry is limited to 1398104 UTF-8 bytes"
        case .inputLimit: "ZIP entries are limited to 1048576 total decoded bytes"
        case .outputLimit: "Complete ZIP output is limited to 2097152 bytes"
        case .internalMismatch: "ZIP encoding could not confirm the preflight plan"
        }
    }
}

/// One call-local, stored ZIP from supplied bytes. It reads no filesystem members.
enum NativeStoredZIPWriter {
    static let maximumEntries = 32
    static let maximumNameBytes = 1_024
    static let maximumComponentBytes = 255
    static let maximumInputBytes = 1_048_576
    static let maximumOutputBytes = 2_097_152
    static let maximumBase64Bytes = ((maximumInputBytes + 2) / 3) * 4
    static let outputContract = "zip-stored-supplied-files-v1"
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    struct EncodedArchive {
        let data: Data
        let entryCount: Int
        let inputBytes: Int
    }

    private struct PlannedEntry {
        let nameBytes: Data
        let content: String
        let rawCount: Int
        let localOffset: Int
    }

    private struct Plan {
        let entries: [PlannedEntry]
        let bodyBytes: Int
        let directoryBytes: Int
        let totalBytes: Int
        let inputBytes: Int
    }

    private static func name(_ supplied: String, cancellation: ToolCallCancellation?) throws -> (Data, String) {
        try cancellation?.checkCancellation()
        guard !supplied.isEmpty else { throw NativeStoredZIPError.invalidName }
        guard supplied.utf8.prefix(maximumNameBytes + 1).count <= maximumNameBytes else {
            throw NativeStoredZIPError.nameLimit
        }
        guard !supplied.hasPrefix("/"), !supplied.hasPrefix("\\"), !supplied.contains("\\"),
              !supplied.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeStoredZIPError.invalidName
        }
        let nfc = supplied.precomposedStringWithCanonicalMapping
        let bytes = Data(supplied.utf8)
        // Swift String equality is canonically equivalent; admission requires exact NFC bytes.
        guard bytes == Data(nfc.utf8) else { throw NativeStoredZIPError.nonNFCName }
        let components = supplied.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !(components.first?.contains(":") ?? false) else { throw NativeStoredZIPError.invalidName }
        for component in components {
            try cancellation?.checkCancellation()
            guard component.utf8.count <= maximumComponentBytes else { throw NativeStoredZIPError.componentLimit }
        }
        // Conservative admission policy, not a portable filesystem collision guarantee.
        let key = nfc.folding(options: [.caseInsensitive], locale: foldingLocale)
            .precomposedStringWithCanonicalMapping
        return (bytes, key)
    }

    private static func sextet(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: return byte - 65
        case 97...122: return byte - 97 + 26
        case 48...57: return byte - 48 + 52
        case 43: return 62
        case 47: return 63
        default: return nil
        }
    }

    private static func rawSize(_ content: String, available: Int,
                                cancellation: ToolCallCancellation?) throws -> Int {
        let count = content.utf8.prefix(maximumBase64Bytes + 1).count
        guard count <= maximumBase64Bytes else { throw NativeStoredZIPError.base64Limit }
        guard count % 4 == 0 else { throw NativeStoredZIPError.invalidBase64 }
        let padding = content.hasSuffix("==") ? 2 : content.hasSuffix("=") ? 1 : 0
        let raw = (count / 4) * 3 - padding
        guard raw >= 0 else { throw NativeStoredZIPError.invalidBase64 }
        guard raw <= available else { throw NativeStoredZIPError.inputLimit }
        var lastSextet: UInt8 = 0
        for (index, byte) in content.utf8.enumerated() {
            if index % 4096 == 0 { try cancellation?.checkCancellation() }
            if index >= count - padding {
                guard byte == 61 else { throw NativeStoredZIPError.invalidBase64 }
            } else {
                guard let value = sextet(byte) else { throw NativeStoredZIPError.invalidBase64 }
                lastSextet = value
            }
        }
        guard padding != 2 || lastSextet & 15 == 0,
              padding != 1 || lastSextet & 3 == 0 else { throw NativeStoredZIPError.invalidBase64 }
        try cancellation?.checkCancellation()
        return raw
    }

    private static func preflight(_ value: Any?, limit: Int,
                                  cancellation: ToolCallCancellation?) throws -> Plan {
        guard (1...maximumOutputBytes).contains(limit) else { throw NativeStoredZIPError.outputLimit }
        guard let rows = value as? [Any] else { throw NativeStoredZIPError.invalidEntries }
        guard rows.count <= maximumEntries else { throw NativeStoredZIPError.entryLimit }
        var entries: [PlannedEntry] = []
        var keys: [String] = []
        var rawTotal = 0, body = 0, directory = 0
        for row in rows {
            try cancellation?.checkCancellation()
            guard let object = row as? [String: Any], Set(object.keys) == ["name", "content"],
                  let suppliedName = object["name"] as? String, let content = object["content"] as? String else {
                throw NativeStoredZIPError.invalidEntry
            }
            let (nameBytes, key) = try name(suppliedName, cancellation: cancellation)
            for prior in keys {
                try cancellation?.checkCancellation()
                guard key != prior, !key.hasPrefix(prior + "/"), !prior.hasPrefix(key + "/") else {
                    throw NativeStoredZIPError.nameCollision
                }
            }
            let size = try rawSize(content, available: maximumInputBytes - rawTotal, cancellation: cancellation)
            let localSize = 30 + nameBytes.count + size
            let centralSize = 46 + nameBytes.count
            guard localSize <= limit - body, centralSize <= limit - directory else { throw NativeStoredZIPError.outputLimit }
            let nextBody = body + localSize, nextDirectory = directory + centralSize
            guard nextBody <= limit - nextDirectory, 22 <= limit - nextBody - nextDirectory else {
                throw NativeStoredZIPError.outputLimit
            }
            entries.append(PlannedEntry(nameBytes: nameBytes, content: content, rawCount: size, localOffset: body))
            keys.append(key); rawTotal += size; body = nextBody; directory = nextDirectory
        }
        guard body <= limit - directory, 22 <= limit - body - directory else { throw NativeStoredZIPError.outputLimit }
        let total = body + directory + 22
        guard total <= maximumOutputBytes, body <= Int(UInt32.max), directory <= Int(UInt32.max),
              entries.count <= Int(UInt16.max) else { throw NativeStoredZIPError.outputLimit }
        try cancellation?.checkCancellation()
        return Plan(entries: entries, bodyBytes: body, directoryBytes: directory,
                    totalBytes: total, inputBytes: rawTotal)
    }

    private static func crc32(_ bytes: Data, cancellation: ToolCallCancellation?) throws -> UInt32 {
        var checksum: UInt32 = 0xFFFFFFFF
        for (index, byte) in bytes.enumerated() {
            if index % 4096 == 0 { try cancellation?.checkCancellation() }
            checksum ^= UInt32(byte)
            for _ in 0..<8 { checksum = (checksum >> 1) ^ ((checksum & 1) == 1 ? 0xEDB88320 : 0) }
        }
        try cancellation?.checkCancellation()
        return checksum ^ 0xFFFFFFFF
    }

    private struct Output {
        let limit: Int
        var data: Data
        init(limit: Int) { self.limit = limit; data = Data(capacity: limit) }
        mutating func append(_ bytes: Data, cancellation: ToolCallCancellation?) throws {
            guard bytes.count <= limit - data.count else { throw NativeStoredZIPError.outputLimit }
            var offset = 0
            while offset < bytes.count {
                try cancellation?.checkCancellation()
                let end = offset + min(65_536, bytes.count - offset)
                data.append(bytes[offset..<end]); offset = end
            }
        }
        mutating func append16(_ value: UInt16) throws {
            guard 2 <= limit - data.count else { throw NativeStoredZIPError.outputLimit }
            data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
        }
        mutating func append32(_ value: UInt32) throws {
            guard 4 <= limit - data.count else { throw NativeStoredZIPError.outputLimit }
            data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                                     UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
        }
    }

    static func encode(entries value: Any?, cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> EncodedArchive {
        guard !Thread.isMainThread else { throw NativeStoredZIPError.workerRequired }
        try cancellation?.checkCancellation()
        let plan = try preflight(value, limit: outputByteLimit, cancellation: cancellation)
        try cancellation?.checkCancellation()
        var output = Output(limit: plan.totalBytes)
        var checksums: [UInt32] = []
        for entry in plan.entries {
            try cancellation?.checkCancellation()
            guard output.data.count == entry.localOffset,
                  let raw = Data(base64Encoded: entry.content), raw.count == entry.rawCount,
                  raw.base64EncodedString() == entry.content else { throw NativeStoredZIPError.internalMismatch }
            let checksum = try crc32(raw, cancellation: cancellation)
            try output.append32(0x04034b50)
            for field in [20, 0x0800, 0, 0, 0x0021] as [UInt16] { try output.append16(field) }
            for field in [checksum, UInt32(raw.count), UInt32(raw.count)] { try output.append32(field) }
            try output.append16(UInt16(entry.nameBytes.count)); try output.append16(0)
            try output.append(entry.nameBytes, cancellation: cancellation)
            try output.append(raw, cancellation: cancellation)
            checksums.append(checksum)
        }
        guard output.data.count == plan.bodyBytes else { throw NativeStoredZIPError.internalMismatch }
        for (index, entry) in plan.entries.enumerated() {
            try cancellation?.checkCancellation()
            try output.append32(0x02014b50)
            for field in [20, 20, 0x0800, 0, 0, 0x0021] as [UInt16] { try output.append16(field) }
            for field in [checksums[index], UInt32(entry.rawCount), UInt32(entry.rawCount)] { try output.append32(field) }
            for field in [UInt16(entry.nameBytes.count), 0, 0, 0, 0] { try output.append16(field) }
            try output.append32(0); try output.append32(UInt32(entry.localOffset))
            try output.append(entry.nameBytes, cancellation: cancellation)
        }
        guard output.data.count == plan.bodyBytes + plan.directoryBytes else { throw NativeStoredZIPError.internalMismatch }
        try cancellation?.checkCancellation(); try output.append32(0x06054b50)
        for field in [0, 0, UInt16(plan.entries.count), UInt16(plan.entries.count)] { try output.append16(field) }
        try output.append32(UInt32(plan.directoryBytes)); try output.append32(UInt32(plan.bodyBytes)); try output.append16(0)
        try cancellation?.checkCancellation()
        guard output.data.count == plan.totalBytes else { throw NativeStoredZIPError.internalMismatch }
        return EncodedArchive(data: output.data, entryCount: plan.entries.count, inputBytes: plan.inputBytes)
    }
}

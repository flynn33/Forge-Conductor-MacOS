import Foundation

enum NativePAXTARError: Error, LocalizedError {
    case admission(NativeStoredZIPError)
    var code: String { switch self { case .admission(let error): error.code } }
    var errorDescription: String? {
        switch self { case .admission(let error): error.localizedDescription.replacingOccurrences(of: "ZIP", with: "TAR") }
    }
}

/// A deterministic PAX/USTAR archive of supplied virtual regular files; no filesystem reads.
enum NativePAXTARWriter {
    static let maximumEntries = NativeStoredZIPWriter.maximumEntries
    static let maximumNameBytes = NativeStoredZIPWriter.maximumNameBytes
    static let maximumComponentBytes = NativeStoredZIPWriter.maximumComponentBytes
    static let maximumInputBytes = NativeStoredZIPWriter.maximumInputBytes
    static let maximumOutputBytes = NativeStoredZIPWriter.maximumOutputBytes
    static let maximumBase64Bytes = NativeStoredZIPWriter.maximumBase64Bytes
    static let outputContract = "tar-pax-supplied-files-v1"
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    private struct Entry {
        let nameBytes: Data
        let content: String
        let rawCount: Int
        let pax: Data
    }
    private struct Plan { let entries: [Entry]; let totalBytes: Int; let inputBytes: Int }

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

    private static func rounded(_ count: Int) -> Int { ((count + 511) / 512) * 512 }

    private static func paxPath(_ name: Data) throws -> Data {
        let suffix = Data(" path=".utf8) + name + Data([10])
        var total = suffix.count + 1
        for _ in 0..<8 {
            let digits = Data(String(total).utf8)
            let next = digits.count + suffix.count
            if next == total {
                guard total <= 1_035 else { throw NativeStoredZIPError.internalMismatch }
                return digits + suffix
            }
            total = next
        }
        throw NativeStoredZIPError.internalMismatch
    }

    private static func preflight(_ value: Any?, limit: Int,
                                  cancellation: ToolCallCancellation?) throws -> Plan {
        guard (1...maximumOutputBytes).contains(limit) else { throw NativeStoredZIPError.outputLimit }
        guard let rows = value as? [Any] else { throw NativeStoredZIPError.invalidEntries }
        guard rows.count <= maximumEntries else { throw NativeStoredZIPError.entryLimit }
        var entries: [Entry] = [], keys: [String] = []
        var rawTotal = 0, total = 1_024
        guard total <= limit else { throw NativeStoredZIPError.outputLimit }
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
            let pax = try paxPath(nameBytes)
            let extent = 1_024 + rounded(pax.count) + rounded(size)
            guard extent <= limit - total else { throw NativeStoredZIPError.outputLimit }
            entries.append(Entry(nameBytes: nameBytes, content: content, rawCount: size, pax: pax))
            keys.append(key); rawTotal += size; total += extent
        }
        try cancellation?.checkCancellation()
        return Plan(entries: entries, totalBytes: total, inputBytes: rawTotal)
    }

    private static func header(index: Int, type: UInt8, size: Int) throws -> Data {
        var bytes = Data(repeating: 0, count: 512)
        func ascii(_ text: String, at offset: Int, capacity: Int) throws {
            let value = Data(text.utf8)
            guard value.count < capacity else { throw NativeStoredZIPError.internalMismatch }
            bytes.replaceSubrange(offset..<(offset + value.count), with: value)
        }
        func octal(_ value: Int, at offset: Int, count: Int) throws {
            let text = String(value, radix: 8)
            guard value >= 0, text.count < count else { throw NativeStoredZIPError.internalMismatch }
            try ascii(String(repeating: "0", count: count - text.count - 1) + text, at: offset, capacity: count)
        }
        let path = String(format: "%@/%08d", type == 120 ? "PaxHeaders" : "ForgeFiles", index)
        try ascii(path, at: 0, capacity: 100)
        try octal(0o644, at: 100, count: 8); try octal(0, at: 108, count: 8)
        try octal(0, at: 116, count: 8); try octal(size, at: 124, count: 12)
        try octal(0, at: 136, count: 12)
        bytes.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
        bytes[156] = type
        try ascii("ustar", at: 257, capacity: 6)
        bytes[263] = 48; bytes[264] = 48
        let checksum = bytes.reduce(0) { $0 + Int($1) }
        let text = String(checksum, radix: 8)
        guard text.count <= 6 else { throw NativeStoredZIPError.internalMismatch }
        bytes.replaceSubrange(148..<154, with: Data((String(repeating: "0", count: 6 - text.count) + text).utf8))
        bytes[154] = 0; bytes[155] = 32
        return bytes
    }

    static func encode(entries value: Any?, cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> NativeStoredZIPWriter.EncodedArchive {
        do {
            guard !Thread.isMainThread else { throw NativeStoredZIPError.workerRequired }
            try cancellation?.checkCancellation()
            let plan = try preflight(value, limit: outputByteLimit, cancellation: cancellation)
            var data = Data(capacity: plan.totalBytes)
            func append(_ bytes: Data) throws {
                guard bytes.count <= plan.totalBytes - data.count else { throw NativeStoredZIPError.internalMismatch }
                var cursor = 0
                while cursor < bytes.count {
                    try cancellation?.checkCancellation()
                    let end = cursor + min(65_536, bytes.count - cursor)
                    data.append(bytes[cursor..<end]); cursor = end
                }
            }
            for (index, entry) in plan.entries.enumerated() {
                try cancellation?.checkCancellation()
                guard let raw = Data(base64Encoded: entry.content), raw.count == entry.rawCount,
                      raw.base64EncodedString() == entry.content else { throw NativeStoredZIPError.internalMismatch }
                try append(header(index: index, type: 120, size: entry.pax.count))
                try append(entry.pax); try append(Data(repeating: 0, count: rounded(entry.pax.count) - entry.pax.count))
                try append(header(index: index, type: 48, size: raw.count))
                try append(raw); try append(Data(repeating: 0, count: rounded(raw.count) - raw.count))
            }
            try append(Data(repeating: 0, count: 1_024)); try cancellation?.checkCancellation()
            guard data.count == plan.totalBytes else { throw NativeStoredZIPError.internalMismatch }
            return NativeStoredZIPWriter.EncodedArchive(data: data, entryCount: plan.entries.count, inputBytes: plan.inputBytes)
        } catch let error as NativeStoredZIPError { throw NativePAXTARError.admission(error) }
    }
}

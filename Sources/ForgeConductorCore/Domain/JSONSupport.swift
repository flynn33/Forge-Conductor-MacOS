// JSONSupport.swift
// What: Centralizes ISO-8601 and JSON serialization used across transports/storage.
// How: Shared encoders enforce valid JSON objects, deterministic formatting choices,
// and one timestamp representation with bounded conversion helpers.
// Why: Protocol boundaries must not disagree about dates or accepted JSON shapes.

import Foundation
import CryptoKit
import CoreFoundation

/// Centralizes deterministic ISO-8601 conversion for persistence and wire adapters.
///
/// `ISO8601DateFormatter` is mutable and not `Sendable`, so access to the shared
/// formatter is serialized rather than duplicating subtly different date policies.
public enum ISO8601 {
    // ISO8601DateFormatter is not Sendable; access is serialized via lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static let _formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let _fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return _formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = _formatter.date(from: string) { return d }
        return _fractional.date(from: string)
    }
}

public enum JSONSupport {
    public enum IntegerFieldRequirement: Sendable { case required, optional, legacyStringCompatible }

    /// Validate count fields from their original JSON tokens, before NSNumber or
    /// Decimal can round a fractional value. Only matched counts are rewritten;
    /// floating measurements and all other content retain their original bytes.
    public static func validatingIntegerFields(
        in data: Data,
        maximumBytes: Int,
        requirement: ([String]) -> IntegerFieldRequirement?
    ) throws -> Data {
        guard data.count <= maximumBytes else {
            throw ManagerSettingsValidationError(field: "settings", reason: "body_too_large")
        }
        var scanner = ExactIntegerJSONScanner(bytes: Array(data))
        return try scanner.scan(requirement: requirement)
    }

    /// Decode an exact machine integer without Foundation's truncating bridges.
    /// Integer strings are an explicit compatibility option for legacy settings.
    public static func exactInteger(_ value: Any?, allowString: Bool = false) -> Int? {
        if allowString, let text = value as? String {
            guard text.utf8.count <= 32 else { return nil }
            return Int(text)
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Decimal numbers can bridge to Int or Double after rounding. Their
        // decimal representation must itself be an integer within Int's range.
        if number is NSDecimalNumber { return Int(number.stringValue) }
        switch String(cString: number.objCType) {
        case "f", "d": return Int(exactly: number.doubleValue)
        default: return Int(number.stringValue)
        }
    }

    public static func data(from object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func string(from object: [String: Any]) throws -> String {
        String(data: try data(from: object), encoding: .utf8) ?? "{}"
    }

    public static func object(from data: Data) throws -> [String: Any] {
        let o = try JSONSerialization.jsonObject(with: data)
        return o as? [String: Any] ?? [:]
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalJSON(_ object: [String: Any]) throws -> String {
        // Sort keys recursively for stable digests
        try string(from: sortKeys(object) as? [String: Any] ?? object)
    }

    private static func sortKeys(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for k in dict.keys.sorted() {
                out[k] = sortKeys(dict[k] as Any)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sortKeys($0) }
        }
        return value
    }
}

/// A bounded structural pass over raw JSON. Foundation remains the model decoder,
/// but it is never asked to establish exactness of an unvalidated count token.
private struct ExactIntegerJSONScanner {
    let bytes: [UInt8]
    var index = 0
    var visitedValues = 0
    var copiedThrough = 0
    var output = Data()

    mutating func scan(requirement: ([String]) -> JSONSupport.IntegerFieldRequirement?) throws -> Data {
        try value(path: [], depth: 0, requirement: requirement)
        whitespace()
        guard index == bytes.count else { throw invalid([]) }
        output.append(contentsOf: bytes[copiedThrough...])
        return output
    }

    mutating func value(path: [String], depth: Int,
                        requirement: ([String]) -> JSONSupport.IntegerFieldRequirement?) throws {
        visitedValues += 1
        guard depth <= 64, visitedValues <= 131_072 else {
            throw ManagerSettingsValidationError(field: field(path), reason: "json_structure_too_large")
        }
        whitespace()
        guard index < bytes.count else { throw invalid(path) }
        if let rule = requirement(path) {
            if rule == .optional, matches("null") { index += 4; return }
            if rule == .legacyStringCompatible, bytes[index] == 34 {
                let text = try string(path: path)
                guard text.utf8.count <= 32, Int(text) != nil else {
                    throw ManagerSettingsValidationError(field: field(path), reason: "expected_exact_integer")
                }
                return
            }
            let start = index
            try number(path: path)
            guard let canonical = Self.exactInteger(bytes[start..<index]) else {
                throw ManagerSettingsValidationError(field: field(path), reason: "expected_exact_integer", permittedRange: "\(Int.min)...\(Int.max)")
            }
            output.append(contentsOf: bytes[copiedThrough..<start])
            output.append(contentsOf: canonical.utf8)
            copiedThrough = index
            return
        }
        switch bytes[index] {
        case 123: // object
            index += 1; whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                let key = try string(path: path)
                guard key.utf8.count <= 1_024 else {
                    throw ManagerSettingsValidationError(field: field(path), reason: "json_field_name_too_long")
                }
                // Compare decoded names so escaped aliases cannot make two
                // Foundation decoders select different authoritative values.
                guard keys.insert(key).inserted else {
                    throw ManagerSettingsValidationError(field: field(path + [key]), reason: "duplicate_field")
                }
                whitespace()
                guard consume(58) else { throw invalid(path) }
                try value(path: path + [key], depth: depth + 1, requirement: requirement)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw invalid(path) }
                whitespace()
            }
        case 91: // array
            index += 1; whitespace()
            if consume(93) { return }
            var item = 0
            while true {
                try value(path: path + [String(item)], depth: depth + 1, requirement: requirement)
                item += 1; whitespace()
                if consume(93) { return }
                guard consume(44) else { throw invalid(path) }
            }
        case 34: _ = try string(path: path)
        case 116 where matches("true"): index += 4
        case 102 where matches("false"): index += 5
        case 110 where matches("null"): index += 4
        default: try number(path: path)
        }
    }

    mutating func string(path: [String]) throws -> String {
        whitespace()
        let start = index
        guard consume(34) else { throw invalid(path) }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw invalid(path)
                }
                return result
            }
            if byte == 92 { // Skip the escaped byte; Foundation validates the escape.
                guard index < bytes.count else { throw invalid(path) }
                index += 1
            }
        }
        throw invalid(path)
    }

    mutating func number(path: [String]) throws {
        let start = index
        _ = consume(45)
        guard index < bytes.count else { throw invalid(path) }
        if consume(48) {
            guard index == bytes.count || !Self.digit(bytes[index]) else { throw invalid(path) }
        } else {
            guard index < bytes.count, (49...57).contains(bytes[index]) else {
                throw ManagerSettingsValidationError(field: field(path), reason: "expected_exact_integer")
            }
            while index < bytes.count, Self.digit(bytes[index]) { index += 1 }
        }
        if consume(46) {
            let fractionStart = index
            while index < bytes.count, Self.digit(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw invalid(path) }
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            let exponentStart = index
            while index < bytes.count, Self.digit(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw invalid(path) }
        }
        guard index - start <= 4_096 else {
            throw ManagerSettingsValidationError(field: field(path), reason: "numeric_token_too_long")
        }
    }

    /// Decimal arithmetic on digits, with no floating conversion or exponent
    /// expansion. The largest temporary is the already bounded input token.
    private static func exactInteger(_ token: ArraySlice<UInt8>) -> String? {
        let parts = token.split(whereSeparator: { $0 == 101 || $0 == 69 })
        guard let mantissa = parts.first else { return nil }
        let negative = mantissa.first == 45
        let decimalIndex = mantissa.firstIndex(of: 46)
        let fractionCount = decimalIndex.map { mantissa.distance(from: mantissa.index(after: $0), to: mantissa.endIndex) } ?? 0
        var digits = mantissa.filter(digit)
        var exponent = 0
        if parts.count == 2 {
            let exponentBytes = parts[1]
            for byte in exponentBytes where digit(byte) {
                exponent = min(10_000, exponent * 10 + Int(byte - 48))
            }
            if exponentBytes.first == 45 { exponent = -exponent }
        }
        guard let firstNonzero = digits.firstIndex(where: { $0 != 48 }) else { return "0" }
        digits.removeFirst(firstNonzero)
        let scale = exponent - fractionCount
        if scale < 0 {
            let remove = -scale
            guard remove <= digits.count, digits.suffix(remove).allSatisfy({ $0 == 48 }) else { return nil }
            digits.removeLast(remove)
        } else {
            guard digits.count + scale <= 19 else { return nil }
            digits.append(contentsOf: repeatElement(48, count: scale))
        }
        guard !digits.isEmpty, digits.count <= 19 else { return nil }
        let magnitude = String(decoding: digits, as: UTF8.self)
        let limit = negative ? "9223372036854775808" : "9223372036854775807"
        guard magnitude.count < limit.count || magnitude <= limit else { return nil }
        return (negative ? "-" : "") + magnitude
    }

    private static func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    private func matches(_ text: StaticString) -> Bool {
        let expected = Array(String(describing: text).utf8)
        return bytes[index...].starts(with: expected)
    }
    private func field(_ path: [String]) -> String { path.isEmpty ? "settings" : path.joined(separator: ".") }
    private func invalid(_ path: [String]) -> ManagerSettingsValidationError {
        ManagerSettingsValidationError(field: field(path), reason: "malformed_json")
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
}

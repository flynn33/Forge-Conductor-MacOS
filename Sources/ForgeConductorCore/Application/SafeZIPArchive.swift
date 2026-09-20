// SafeZIPArchive.swift
// Bounded ZIP container inspection and extraction through the native macOS ditto facility.

import Foundation

enum SafeZIPArchiveError: Error, LocalizedError, Equatable {
    case malformed(String)
    case unsafePath(String)
    case link(String)
    case encrypted(String)
    case unsupportedCompression(Int)
    case resourceLimit(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): "The ZIP container is malformed: \(detail)"
        case .unsafePath(let path): "The ZIP contains an unsafe path: \(path)"
        case .link(let path): "The ZIP contains a link or unsupported filesystem entry: \(path)"
        case .encrypted(let path): "The ZIP entry is encrypted and cannot be converted: \(path)"
        case .unsupportedCompression(let method): "The ZIP uses unsupported compression method \(method)."
        case .resourceLimit(let detail): "The ZIP exceeds the safe extraction budget: \(detail)"
        case .extractionFailed(let detail): "The ZIP could not be extracted safely: \(detail)"
        }
    }
}

struct SafeZIPArchive {
    struct Entry: Equatable {
        let path: String
        let compressedBytes: Int
        let uncompressedBytes: Int
        let isDirectory: Bool
    }

    static let maximumEntries = 4_096
    static let maximumEntryBytes = 128 * 1_048_576
    static let maximumExpandedBytes = 512 * 1_048_576
    static let maximumExpansionRatio = 200
    static let extractionDeadline: TimeInterval = 60

    static func isZIP(_ data: Data, path: String) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || data.starts(with: [0x50, 0x4B, 0x05, 0x06])
            || path.lowercased().hasSuffix(".zip")
    }

    static func inspect(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw SafeZIPArchiveError.malformed("end record is missing") }
        let searchStart = max(0, data.count - 65_557)
        var endOffset: Int?
        var cursor = data.count - 22
        while cursor >= searchStart {
            if uint32(data, cursor) == 0x0605_4B50,
               cursor <= data.count - 22,
               cursor + 22 + Int(uint16(data, cursor + 20)) == data.count {
                endOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let endOffset else { throw SafeZIPArchiveError.malformed("end record is missing") }
        let commentLength = Int(uint16(data, endOffset + 20))
        assert(endOffset + 22 + commentLength == data.count)
        guard uint16(data, endOffset + 4) == 0,
              uint16(data, endOffset + 6) == 0 else {
            throw SafeZIPArchiveError.malformed("multi-disk archives are not supported")
        }
        let diskEntries = Int(uint16(data, endOffset + 8))
        let entryCount = Int(uint16(data, endOffset + 10))
        guard diskEntries == entryCount, entryCount <= maximumEntries else {
            throw SafeZIPArchiveError.resourceLimit("entry count is inconsistent or exceeds \(maximumEntries)")
        }
        let centralSize = Int(uint32(data, endOffset + 12))
        let centralOffset = Int(uint32(data, endOffset + 16))
        guard centralOffset <= data.count,
              centralSize <= data.count - centralOffset,
              centralOffset + centralSize <= endOffset else {
            throw SafeZIPArchiveError.malformed("central directory is outside the container")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var seen: Set<String> = []
        var expanded = 0
        cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor <= data.count - 46, uint32(data, cursor) == 0x0201_4B50 else {
                throw SafeZIPArchiveError.malformed("central directory entry is truncated")
            }
            let versionMadeBy = uint16(data, cursor + 4)
            let flags = uint16(data, cursor + 8)
            let method = Int(uint16(data, cursor + 10))
            let compressed = Int(uint32(data, cursor + 20))
            let uncompressed = Int(uint32(data, cursor + 24))
            let nameLength = Int(uint16(data, cursor + 28))
            let extraLength = Int(uint16(data, cursor + 30))
            let commentLength = Int(uint16(data, cursor + 32))
            let disk = uint16(data, cursor + 34)
            let externalAttributes = uint32(data, cursor + 38)
            let localOffset = Int(uint32(data, cursor + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, cursor <= data.count - recordLength, disk == 0 else {
                throw SafeZIPArchiveError.malformed("central directory fields are inconsistent")
            }
            let nameData = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw SafeZIPArchiveError.malformed("entry name is not valid UTF-8")
            }
            let path = try validatedPath(rawName)
            guard seen.insert(path).inserted else {
                throw SafeZIPArchiveError.malformed("duplicate entry path \(path)")
            }
            guard flags & 0x0001 == 0 else { throw SafeZIPArchiveError.encrypted(path) }
            guard method == 0 || method == 8 else {
                throw SafeZIPArchiveError.unsupportedCompression(method)
            }
            guard uncompressed <= maximumEntryBytes else {
                throw SafeZIPArchiveError.resourceLimit("\(path) exceeds \(maximumEntryBytes) expanded bytes")
            }
            guard expanded <= maximumExpandedBytes - uncompressed else {
                throw SafeZIPArchiveError.resourceLimit("expanded content exceeds \(maximumExpandedBytes) bytes")
            }
            if uncompressed > 1_048_576,
               uncompressed > compressed * maximumExpansionRatio + 1_048_576 {
                throw SafeZIPArchiveError.resourceLimit("\(path) has an excessive expansion ratio")
            }
            let madeByUnix = versionMadeBy >> 8 == 3
            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            let unixType = unixMode & 0o170000
            let dosDirectory = externalAttributes & 0x10 != 0
            let isDirectory = rawName.hasSuffix("/") || dosDirectory || unixType == 0o040000
            if madeByUnix, unixType != 0, unixType != 0o100000, unixType != 0o040000 {
                throw SafeZIPArchiveError.link(path)
            }
            try validateLocalHeader(
                data, offset: localOffset, expectedName: nameData,
                expectedMethod: method, expectedFlags: flags,
                compressedBytes: compressed, centralOffset: centralOffset
            )
            entries.append(Entry(
                path: path,
                compressedBytes: compressed,
                uncompressedBytes: uncompressed,
                isDirectory: isDirectory
            ))
            expanded += uncompressed
            cursor += recordLength
        }
        guard cursor == centralOffset + centralSize else {
            throw SafeZIPArchiveError.malformed("central directory size does not match its entries")
        }
        return entries
    }

    static func extract(_ inspectedData: Data, to destination: URL, expected: [Entry]) throws {
        if Task.isCancelled { throw CancellationError() }
        let inspectedArchive = destination.deletingLastPathComponent().appendingPathComponent(
            "forge-inspected-\(UUID().uuidString.lowercased()).zip"
        )
        do {
            try inspectedData.write(to: inspectedArchive, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: inspectedArchive.path
            )
        } catch {
            throw SafeZIPArchiveError.extractionFailed(
                "the inspected container could not be staged: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: inspectedArchive) }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", inspectedArchive.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { throw SafeZIPArchiveError.extractionFailed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(extractionDeadline)
        var completed = false
        while Date() < deadline {
            if finished.wait(timeout: .now() + .milliseconds(100)) == .success {
                completed = true
                break
            }
            if Task.isCancelled {
                process.terminate()
                _ = finished.wait(timeout: .now() + 5)
                throw CancellationError()
            }
        }
        guard completed else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw SafeZIPArchiveError.extractionFailed("the native extractor exceeded its 60-second deadline")
        }
        guard process.terminationStatus == 0 else {
            throw SafeZIPArchiveError.extractionFailed("the native extractor returned status \(process.terminationStatus)")
        }
        try validateExtractedTree(destination, expected: expected)
    }

    private static func validateExtractedTree(_ root: URL, expected: [Entry]) throws {
        let expectedFiles = Dictionary(uniqueKeysWithValues: expected.filter { !$0.isDirectory }.map {
            ($0.path, $0.uncompressedBytes)
        })
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw SafeZIPArchiveError.extractionFailed("the extracted tree cannot be inventoried") }
        var actual: [String: Int] = [:]
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            let relative = try relativePath(url, root: root)
            if values.isSymbolicLink == true { throw SafeZIPArchiveError.link(relative) }
            if values.isRegularFile == true {
                guard actual[relative] == nil else {
                    throw SafeZIPArchiveError.extractionFailed("duplicate extracted path \(relative)")
                }
                actual[relative] = values.fileSize ?? -1
            } else if values.isDirectory != true {
                throw SafeZIPArchiveError.link(relative)
            }
        }
        guard actual == expectedFiles else {
            throw SafeZIPArchiveError.extractionFailed(
                "the extracted file inventory or byte sizes differ from the inspected container"
            )
        }
    }

    private static func validateLocalHeader(
        _ data: Data,
        offset: Int,
        expectedName: Data.SubSequence,
        expectedMethod: Int,
        expectedFlags: UInt16,
        compressedBytes: Int,
        centralOffset: Int
    ) throws {
        guard offset >= 0, offset <= data.count - 30, uint32(data, offset) == 0x0403_4B50 else {
            throw SafeZIPArchiveError.malformed("local entry header is missing")
        }
        let flags = uint16(data, offset + 6)
        let method = Int(uint16(data, offset + 8))
        let nameLength = Int(uint16(data, offset + 26))
        let extraLength = Int(uint16(data, offset + 28))
        let dataOffset = offset + 30 + nameLength + extraLength
        guard flags == expectedFlags, method == expectedMethod,
              dataOffset <= data.count,
              compressedBytes <= data.count - dataOffset,
              dataOffset + compressedBytes <= centralOffset,
              nameLength == expectedName.count,
              data[(offset + 30)..<(offset + 30 + nameLength)].elementsEqual(expectedName) else {
            throw SafeZIPArchiveError.malformed("local and central entry headers disagree")
        }
    }

    private static func validatedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= 4_096,
              !raw.hasPrefix("/"), !raw.hasPrefix("\\"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SafeZIPArchiveError.unsafePath(String(raw.prefix(256)))
        }
        let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !(components.first?.contains(":") ?? false) else {
            throw SafeZIPArchiveError.unsafePath(String(raw.prefix(256)))
        }
        return path
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else {
            throw SafeZIPArchiveError.unsafePath(path)
        }
        return String(path.dropFirst(base.count + 1))
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

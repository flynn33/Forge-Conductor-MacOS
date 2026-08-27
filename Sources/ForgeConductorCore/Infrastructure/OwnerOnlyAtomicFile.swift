// OwnerOnlyAtomicFile.swift
// What: Reads and replaces small security-sensitive files through bounded POSIX operations.
// How: No-follow descriptors, owner-only temporary files, fsync, and same-directory rename preserve integrity.
// Why: Ledger and continuity artifacts must remain portable, private, bounded, and crash durable.

import Darwin
import Foundation

public enum OwnerOnlyAtomicFileError: Error, LocalizedError, Sendable {
    case invalidLimit
    case openFailed(path: String, code: Int32)
    case inspectFailed(path: String, code: Int32)
    case notRegularFile(path: String)
    case fileTooLarge(path: String, maximumBytes: Int)
    case readFailed(path: String, code: Int32)
    case writeFailed(path: String, code: Int32)
    case createDirectoryFailed(path: String, code: Int32)
    case notDirectory(path: String)
    case synchronizeFailed(path: String, code: Int32)
    case renameFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "The file-size limit must be positive."
        case .openFailed(let path, let code):
            "Could not open \(path) (errno \(code))."
        case .inspectFailed(let path, let code):
            "Could not inspect \(path) (errno \(code))."
        case .notRegularFile(let path):
            "Refusing to access non-regular file \(path)."
        case .fileTooLarge(let path, let maximumBytes):
            "File \(path) exceeds the \(maximumBytes)-byte limit."
        case .readFailed(let path, let code):
            "Could not read \(path) (errno \(code))."
        case .writeFailed(let path, let code):
            "Could not write \(path) (errno \(code))."
        case .createDirectoryFailed(let path, let code):
            "Could not create directory \(path) (errno \(code))."
        case .notDirectory(let path):
            "Expected a directory at \(path)."
        case .synchronizeFailed(let path, let code):
            "Could not synchronize \(path) (errno \(code))."
        case .renameFailed(let path, let code):
            "Could not atomically replace \(path) (errno \(code))."
        }
    }
}

public enum OwnerOnlyAtomicFile {
    public static func read(from url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { throw OwnerOnlyAtomicFileError.invalidLimit }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw OwnerOnlyAtomicFileError.openFailed(path: url.path, code: errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw OwnerOnlyAtomicFileError.inspectFailed(path: url.path, code: errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw OwnerOnlyAtomicFileError.notRegularFile(path: url.path)
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw OwnerOnlyAtomicFileError.fileTooLarge(
                path: url.path,
                maximumBytes: maximumBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard data.count <= maximumBytes - count else {
                    throw OwnerOnlyAtomicFileError.fileTooLarge(
                        path: url.path,
                        maximumBytes: maximumBytes
                    )
                }
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw OwnerOnlyAtomicFileError.readFailed(path: url.path, code: errno)
        }
    }

    public static func write(_ data: Data, to destination: URL) throws {
        try write(
            data,
            to: destination,
            directorySynchronizer: synchronizeDirectory
        )
    }

    static func write(
        _ data: Data,
        to destination: URL,
        directorySynchronizer: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try createDurableDirectoryHierarchy(
            at: directory,
            directorySynchronizer: directorySynchronizer
        )

        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = temporary.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw OwnerOnlyAtomicFileError.openFailed(path: temporary.path, code: errno)
        }

        var installed = false
        defer {
            _ = Darwin.close(descriptor)
            if !installed { try? fileManager.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw OwnerOnlyAtomicFileError.writeFailed(path: temporary.path, code: errno)
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw OwnerOnlyAtomicFileError.writeFailed(path: temporary.path, code: errno)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw OwnerOnlyAtomicFileError.synchronizeFailed(path: temporary.path, code: errno)
        }

        let renameResult = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard renameResult == 0 else {
            throw OwnerOnlyAtomicFileError.renameFailed(path: destination.path, code: errno)
        }
        installed = true

        try directorySynchronizer(directory)
    }

    private static func createDurableDirectoryHierarchy(
        at directory: URL,
        directorySynchronizer: (URL) throws -> Void
    ) throws {
        var missing: [URL] = []
        var ancestor = directory.standardizedFileURL
        var ancestorIsDirectory: ObjCBool = false
        while !FileManager.default.fileExists(
            atPath: ancestor.path,
            isDirectory: &ancestorIsDirectory
        ) {
            guard ancestor.path != "/" else {
                throw OwnerOnlyAtomicFileError.createDirectoryFailed(
                    path: directory.path,
                    code: ENOENT
                )
            }
            missing.append(ancestor)
            ancestor.deleteLastPathComponent()
        }
        guard ancestorIsDirectory.boolValue else {
            throw OwnerOnlyAtomicFileError.notDirectory(path: ancestor.path)
        }

        for component in missing.reversed() {
            let createResult = component.path.withCString {
                Darwin.mkdir($0, mode_t(S_IRWXU))
            }
            if createResult != 0 {
                let createCode = errno
                var isDirectory: ObjCBool = false
                guard createCode == EEXIST,
                      FileManager.default.fileExists(
                        atPath: component.path,
                        isDirectory: &isDirectory
                      ), isDirectory.boolValue else {
                    throw OwnerOnlyAtomicFileError.createDirectoryFailed(
                        path: component.path,
                        code: createCode
                    )
                }
                continue
            }
            guard component.path.withCString({ Darwin.chmod($0, mode_t(S_IRWXU)) }) == 0 else {
                throw OwnerOnlyAtomicFileError.createDirectoryFailed(
                    path: component.path,
                    code: errno
                )
            }
            try directorySynchronizer(component)
            try directorySynchronizer(component.deletingLastPathComponent())
        }
    }

    public static func removeIfExists(at destination: URL) throws {
        var information = stat()
        let inspection = destination.path.withCString { Darwin.lstat($0, &information) }
        if inspection != 0 {
            guard errno == ENOENT else {
                throw OwnerOnlyAtomicFileError.inspectFailed(
                    path: destination.path,
                    code: errno
                )
            }
            var parentIsDirectory: ObjCBool = false
            let parent = destination.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: parent.path,
                isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue {
                try synchronizeDirectory(parent)
            }
            return
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw OwnerOnlyAtomicFileError.notRegularFile(path: destination.path)
        }
        guard destination.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw OwnerOnlyAtomicFileError.writeFailed(
                path: destination.path,
                code: errno
            )
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw OwnerOnlyAtomicFileError.openFailed(
                path: directory.path,
                code: errno
            )
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            let code = errno
            _ = Darwin.close(directoryDescriptor)
            throw OwnerOnlyAtomicFileError.synchronizeFailed(
                path: directory.path,
                code: code
            )
        }
        guard Darwin.close(directoryDescriptor) == 0 else {
            throw OwnerOnlyAtomicFileError.synchronizeFailed(
                path: directory.path,
                code: errno
            )
        }
    }
}

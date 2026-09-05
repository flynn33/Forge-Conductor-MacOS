import CryptoKit
import Darwin
import Foundation

public struct QualificationInputSnapshot: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let bytes: Int64
        public let mode: UInt16
        public let sha256: String
    }

    public let files: [File]
    public let absentInputs: [String]
    public let sha256: String
}

/// Bounded, descriptor-relative qualification reads. No symlinks, hard links,
/// special files, or evidence-directory traversal can acquire input authority.
/// Actor isolation keeps traversal and hashing away from the main actor.
public actor QualificationInputSnapshotter {
    private let root: URL
    private let inputs: [String]
    private let maximumBytes: Int64
    private let maximumFiles: Int
    private let maximumFileBytes: Int64

    public init(root: URL, inputs: [String], maximumBytes: Int64 = 256 * 1_048_576, maximumFiles: Int = 10_000,
                maximumFileBytes: Int64 = 32 * 1_048_576) throws {
        guard root.isFileURL, root.path.hasPrefix("/"),
              !inputs.isEmpty, inputs.count <= 256, Set(inputs).count == inputs.count,
              inputs.allSatisfy({ input in
                  !input.isEmpty && input.utf8.count <= 2_048 && !input.hasPrefix("/")
                      && input.split(separator: "/", omittingEmptySubsequences: false)
                          .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
              }), (1...256 * 1_048_576).contains(maximumBytes), (1...10_000).contains(maximumFiles),
              (1...256 * 1_048_576).contains(maximumFileBytes) else {
            throw AutonomyError.invalidRequest("qualification input policy is invalid")
        }
        self.root = root.standardizedFileURL
        self.inputs = inputs.sorted()
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        self.maximumFileBytes = maximumFileBytes
    }

    public func capture() throws -> QualificationInputSnapshot {
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw invalid("cannot open qualification root") }
        defer { Darwin.close(rootDescriptor) }
        let rootIdentity = try inspect(rootDescriptor)
        let deadline = ContinuousClock.now + .seconds(30)
        var files: [QualificationInputSnapshot.File] = []
        var absent: [String] = []
        var visited = Set<String>()
        var bytes: Int64 = 0
        var nodes = 0

        func checkBudget() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, nodes <= maximumFiles * 4 else {
                throw invalid("qualification capture exceeded its traversal deadline or node budget")
            }
        }

        func walk(parent: Int32, name: String, path: String, depth: Int, optional: Bool) throws {
            try checkBudget()
            guard depth <= 64, path.utf8.count <= 2_048 else { throw invalid("qualification path exceeds its bound") }
            guard visited.insert(path).inserted else { return }
            nodes += 1
            let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else {
                if optional && errno == ENOENT { absent.append(path); return }
                throw invalid("qualification input could not be opened without following links: \(path)")
            }
            defer { Darwin.close(descriptor) }
            let before = try inspect(descriptor)
            switch before.st_mode & S_IFMT {
            case S_IFDIR:
                let duplicate = Darwin.dup(descriptor)
                guard duplicate >= 0 else { throw invalid("qualification directory duplication failed") }
                guard let directory = Darwin.fdopendir(duplicate) else {
                    Darwin.close(duplicate)
                    throw invalid("qualification directory could not be enumerated")
                }
                defer { Darwin.closedir(directory) }
                while true {
                    errno = 0
                    guard let entry = Darwin.readdir(directory) else {
                        guard errno == 0 else { throw invalid("qualification directory enumeration failed") }
                        break
                    }
                    let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if child == "." || child == ".." { continue }
                    try walk(parent: descriptor, name: child, path: path + "/" + child, depth: depth + 1, optional: false)
                }
            case S_IFREG:
                guard before.st_nlink == 1 else {
                    throw invalid("qualification file has external hard links: \(path)")
                }
                guard before.st_size >= 0, before.st_size <= maximumFileBytes, files.count < maximumFiles else {
                    throw invalid("qualification file exceeds its size or count bound: \(path)")
                }
                var hasher = SHA256()
                var fileBytes: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
                while true {
                    try checkBudget()
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw invalid("qualification input read failed") }
                    if count == 0 { break }
                    fileBytes += Int64(count)
                    bytes += Int64(count)
                    guard bytes <= maximumBytes, fileBytes <= maximumFileBytes else {
                        throw invalid("qualification input byte budget exceeded")
                    }
                    hasher.update(data: Data(buffer.prefix(count)))
                }
                guard fileBytes == before.st_size else { throw invalid("qualification file changed while reading") }
                files.append(.init(
                    path: path, bytes: fileBytes, mode: UInt16(before.st_mode & 0o777),
                    sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
                ))
            default:
                throw invalid("qualification input is not a regular file or directory: \(path)")
            }
            guard unchanged(before, try inspect(descriptor)) else { throw invalid("qualification input changed during capture: \(path)") }
        }

        for input in inputs {
            var parent = Darwin.dup(rootDescriptor)
            guard parent >= 0 else { throw invalid("qualification root duplication failed") }
            defer { Darwin.close(parent) }
            let components = input.split(separator: "/").map(String.init)
            var parentMissing = false
            for component in components.dropLast() {
                let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT { parentMissing = true; break }
                guard next >= 0 else { throw invalid("qualification parent is unavailable or a link") }
                Darwin.close(parent)
                parent = next
            }
            if parentMissing { absent.append(input); continue }
            try walk(parent: parent, name: components.last!, path: input, depth: components.count, optional: true)
        }
        let currentRoot = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentRoot >= 0 else { throw invalid("qualification root disappeared") }
        defer { Darwin.close(currentRoot) }
        guard unchanged(rootIdentity, try inspect(currentRoot)) else { throw invalid("qualification root changed during capture") }
        files.sort { $0.path < $1.path }
        absent.sort()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = QualificationInputSnapshot(files: files, absentInputs: absent, sha256: "")
        return QualificationInputSnapshot(files: files, absentInputs: absent, sha256: JSONSupport.sha256Hex(try encoder.encode(payload)))
    }

    private func inspect(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw invalid("qualification descriptor inspection failed") }
        return value
    }

    private func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func invalid(_ message: String) -> AutonomyError { .invalidRequest(message) }
}

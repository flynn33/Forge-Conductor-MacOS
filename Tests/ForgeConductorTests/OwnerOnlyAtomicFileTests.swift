import Darwin
import XCTest
@testable import ForgeConductorCore

final class OwnerOnlyAtomicFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "owner-only-file-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteAtomicallyReplacesContentWithOwnerOnlyPermissions() throws {
        let url = root.appendingPathComponent("ledger.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750],
            ofItemAtPath: root.path
        )
        try OwnerOnlyAtomicFile.write(Data("first".utf8), to: url)
        try OwnerOnlyAtomicFile.write(Data("second".utf8), to: url)

        XCTAssertEqual(
            try OwnerOnlyAtomicFile.read(from: url, maximumBytes: 64),
            Data("second".utf8)
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o750)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["ledger.json"]
        )
    }

    func testWritePropagatesDirectorySynchronizationFailure() throws {
        let url = root.appendingPathComponent("ledger.json")
        enum SynchronizationFailure: Error { case injected }

        XCTAssertThrowsError(
            try OwnerOnlyAtomicFile.write(
                Data("committed-but-not-confirmed-durable".utf8),
                to: url,
                directorySynchronizer: { _ in throw SynchronizationFailure.injected }
            )
        ) { error in
            XCTAssertTrue(error is SynchronizationFailure, "unexpected error: \(error)")
        }
        XCTAssertEqual(
            try OwnerOnlyAtomicFile.read(from: url, maximumBytes: 64),
            Data("committed-but-not-confirmed-durable".utf8)
        )
    }

    func testWriteSynchronizesEachCreatedDirectoryAndParentEntry() throws {
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = first.appendingPathComponent("second", isDirectory: true)
        let url = second.appendingPathComponent("ledger.json")
        var synchronized: [String] = []

        try OwnerOnlyAtomicFile.write(
            Data("durable hierarchy".utf8),
            to: url,
            directorySynchronizer: { directory in
                synchronized.append(directory.standardizedFileURL.path)
                try OwnerOnlyAtomicFile.synchronizeDirectory(directory)
            }
        )

        XCTAssertEqual(
            synchronized,
            [first.path, root.path, second.path, first.path, second.path]
        )
        for directory in [first, second] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertEqual(
            try OwnerOnlyAtomicFile.read(from: url, maximumBytes: 64),
            Data("durable hierarchy".utf8)
        )
    }

    func testDirectoryHierarchyFailureStopsBeforeFileReplacement() throws {
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = first.appendingPathComponent("second", isDirectory: true)
        let url = second.appendingPathComponent("ledger.json")
        enum SynchronizationFailure: Error { case injected }
        var synchronized: [String] = []

        XCTAssertThrowsError(try OwnerOnlyAtomicFile.write(
            Data("not installed".utf8),
            to: url,
            directorySynchronizer: { directory in
                synchronized.append(directory.standardizedFileURL.path)
                if directory.standardizedFileURL == self.root.standardizedFileURL {
                    throw SynchronizationFailure.injected
                }
                try OwnerOnlyAtomicFile.synchronizeDirectory(directory)
            }
        )) { error in
            XCTAssertTrue(error is SynchronizationFailure, "unexpected error: \(error)")
        }

        XCTAssertEqual(synchronized, [first.path, root.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadRejectsOversizedAndSpecialFiles() throws {
        let oversized = root.appendingPathComponent("oversized")
        try Data(repeating: 0x41, count: 65).write(to: oversized)
        XCTAssertThrowsError(try OwnerOnlyAtomicFile.read(from: oversized, maximumBytes: 64)) {
            guard case OwnerOnlyAtomicFileError.fileTooLarge = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)
        let start = Date()
        XCTAssertThrowsError(try OwnerOnlyAtomicFile.read(from: fifo, maximumBytes: 64)) {
            guard case OwnerOnlyAtomicFileError.notRegularFile = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }

    func testReadDoesNotFollowSymlinksAndWriteDoesNotModifyTheirTargets() throws {
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try OwnerOnlyAtomicFile.read(from: link, maximumBytes: 64))
        try OwnerOnlyAtomicFile.write(Data("replacement".utf8), to: link)

        XCTAssertEqual(try Data(contentsOf: target), Data("outside".utf8))
        XCTAssertEqual(try OwnerOnlyAtomicFile.read(from: link, maximumBytes: 64), Data("replacement".utf8))
    }
}

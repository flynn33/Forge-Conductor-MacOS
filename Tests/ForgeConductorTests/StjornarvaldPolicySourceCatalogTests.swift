import Darwin
import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldPolicySourceCatalogTests: XCTestCase {
    func testSourceCatalogAndViolationLogShareVersionedDatabaseInEitherOpenOrder() throws {
        let sourceFirst = try SourceFixture()
        _ = try sourceFirst.makeCatalog()
        _ = try StjornarvaldPolicyLogStore(
            databaseURL: sourceFirst.database,
            jsonlURL: sourceFirst.jsonl
        )

        let logFirst = try SourceFixture()
        _ = try StjornarvaldPolicyLogStore(
            databaseURL: logFirst.database,
            jsonlURL: logFirst.jsonl
        )
        _ = try logFirst.makeCatalog()
    }

    func testEveryFormatSizeAndSpecialEntryReturnsDurableAcceptedIdentityBeforeIndexing() async throws {
        let fixture = try SourceFixture()
        let directory = try fixture.directory("folder")
        _ = try fixture.directory("Policy.app")
        let fixtures: [URL] = [
            try fixture.file("policy.md", data: Data("Native policy".utf8)),
            try fixture.file("policy.json", data: Data("{\"rule\":true}".utf8)),
            try fixture.file("policy.plist", data: try PropertyListSerialization.data(
                fromPropertyList: ["rule": "native"], format: .xml, options: 0
            )),
            try fixture.file("policy.rtf", data: Data("{\\rtf1\\ansi Native policy}".utf8)),
            try fixture.file("policy.pdf", data: Data("%PDF-1.7\n/Encrypt true\n".utf8)),
            try fixture.file("policy.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x00])),
            try fixture.file("policy.mov", data: Data([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70])),
            try fixture.file("policy.zip", data: minimalZIP(path: "policy.txt")),
            try fixture.file("unknown.bin", data: Data([0x00, 0xFF, 0x10, 0x80])),
            try fixture.file("empty", data: Data()),
            directory,
            fixture.root.appendingPathComponent("Policy.app", isDirectory: true),
            try fixture.symbolicLink("policy-link", destination: directory),
            try fixture.fifo("policy-fifo"),
            URL(fileURLWithPath: "/dev/null"),
            URL(fileURLWithPath: "/bin/echo"),
        ]
        let huge = fixture.root.appendingPathComponent("huge-policy.bin")
        try Data().write(to: huge)
        XCTAssertEqual(Darwin.truncate(huge.path, 2 * 1_024 * 1_024 * 1_024), 0)
        var allFixtures = fixtures
        allFixtures.append(huge)

        let catalog = try fixture.makeCatalog()
        let start = ContinuousClock.now
        var identities = Set<PolicySourceID>()
        for (index, url) in allFixtures.enumerated() {
            let source = try await catalog.add(
                selectedURL: url,
                requestID: stableUUID(prefix: 0x10, index: index)
            )
            XCTAssertTrue(source.active)
            XCTAssertEqual(source.interpretationState, .accepted)
            XCTAssertNil(source.latestRevisionID)
            identities.insert(source.id)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(identities.count, allFixtures.count)

        let reopened = try fixture.makeCatalog()
        let durable = try reopened.sources(includeRemoved: false)
        XCTAssertEqual(durable.count, allFixtures.count)
        XCTAssertTrue(durable.allSatisfy { $0.interpretationState == .accepted && $0.latestRevisionID == nil })
    }

    func testLargeFileHashingIsBoundedResumableAndRestartSafe() async throws {
        let fixture = try SourceFixture()
        var data = Data((0..<(StjornarvaldNativePolicyExtractor.maximumInputBytes + 300_000)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        data.replaceSubrange(0..<4, with: [0xFE, 0xED, 0xFA, 0xCF])
        let file = try fixture.file("large-policy.bin", data: data)
        var catalog: StjornarvaldPolicySourceCatalog? = try fixture.makeCatalog()
        let source = try await catalog!.add(
            selectedURL: file,
            requestID: stableUUID(prefix: 0x20, index: 1)
        )
        try catalog!.scheduleOrThrow(sourceID: source.id)
        var progress = try catalog!.runNextBatch(
            sourceID: source.id, maximumWorkItems: 2, maximumBytes: 32 * 1_024
        )
        XCTAssertEqual(progress.interpretationState, .cataloging)
        XCTAssertGreaterThan(progress.pendingWorkCount, 0)
        XCTAssertNotNil(progress.cursor)
        catalog = nil

        catalog = try fixture.makeCatalog()
        var passes = 1
        while progress.pendingWorkCount > 0, passes < 200 {
            progress = try catalog!.runNextBatch(
                sourceID: source.id, maximumWorkItems: 1, maximumBytes: 32 * 1_024
            )
            passes += 1
        }
        XCTAssertGreaterThan(passes, 2)
        XCTAssertEqual(progress.pendingWorkCount, 0)
        XCTAssertEqual(progress.interpretationState, .partiallyIndexed)
        let revisionID = try XCTUnwrap(progress.revisionID)
        let artifact = try XCTUnwrap(catalog!.artifacts(revisionID: revisionID).first)
        XCTAssertEqual(artifact.byteCount, Int64(data.count))
        XCTAssertEqual(artifact.contentSHA256, JSONSupport.sha256Hex(data))
        XCTAssertEqual(artifact.kind, .executable)
        XCTAssertEqual(artifact.interpretationState, .partiallyIndexed)
    }

    func testDirectoryTraversalIsBoundedRestartableAndDoesNotFollowLinkCycle() async throws {
        let fixture = try SourceFixture()
        let tree = try fixture.directory("tree")
        for index in 0..<150 {
            try Data("rule \(index)".utf8).write(
                to: tree.appendingPathComponent(String(format: "%03d.md", index)), options: .atomic
            )
        }
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("cycle"), withDestinationURL: tree
        )
        var catalog: StjornarvaldPolicySourceCatalog? = try fixture.makeCatalog()
        let source = try await catalog!.add(
            selectedURL: tree,
            requestID: stableUUID(prefix: 0x30, index: 1)
        )
        try catalog!.scheduleOrThrow(sourceID: source.id)
        var progress = try catalog!.runNextBatch(
            sourceID: source.id, maximumWorkItems: 2, maximumBytes: 64 * 1_024
        )
        XCTAssertGreaterThan(progress.pendingWorkCount, 0)
        catalog = nil

        catalog = try fixture.makeCatalog()
        var passes = 0
        while progress.pendingWorkCount > 0, passes < 1_000 {
            progress = try catalog!.runNextBatch(
                sourceID: source.id, maximumWorkItems: 8, maximumBytes: 128 * 1_024
            )
            passes += 1
        }
        XCTAssertLessThan(passes, 1_000)
        XCTAssertEqual(progress.pendingWorkCount, 0)
        XCTAssertEqual(progress.artifactCount, 152)
        let revisionID = try XCTUnwrap(progress.revisionID)
        let artifacts = try catalog!.artifacts(revisionID: revisionID, limit: 1_000)
        XCTAssertEqual(Set(artifacts.map(\.relativePath)).count, artifacts.count)
        let cycle = try XCTUnwrap(artifacts.first { $0.relativePath == "cycle" })
        XCTAssertEqual(cycle.kind, .symbolicLink)
        XCTAssertEqual(cycle.interpretationState, .metadataOnly)
    }

    func testSourceChangePreservesPriorRevisionAndRefreshBuildsSuccessor() async throws {
        let fixture = try SourceFixture()
        let original = Data(repeating: 0x61, count: 600_000)
        let file = try fixture.file("changing-policy.txt", data: original)
        let catalog = try fixture.makeCatalog()
        let source = try await catalog.add(
            selectedURL: file,
            requestID: stableUUID(prefix: 0x40, index: 1)
        )
        try catalog.scheduleOrThrow(sourceID: source.id)
        var progress = try catalog.runNextBatch(
            sourceID: source.id, maximumWorkItems: 2, maximumBytes: 32 * 1_024
        )
        let firstRevision = try XCTUnwrap(progress.revisionID)
        try Data(repeating: 0x62, count: 700_000).write(to: file, options: .atomic)
        progress = try catalog.runNextBatch(
            sourceID: source.id, maximumWorkItems: 1, maximumBytes: 32 * 1_024
        )
        XCTAssertEqual(progress.interpretationState, .refreshPending)
        XCTAssertEqual(progress.pendingWorkCount, 0)

        try await catalog.refresh(
            sourceID: source.id,
            requestID: stableUUID(prefix: 0x40, index: 2)
        )
        progress = try catalog.progress(sourceID: source.id)
        let secondRevision = try XCTUnwrap(progress.revisionID)
        XCTAssertNotEqual(firstRevision, secondRevision)
        while progress.pendingWorkCount > 0 {
            progress = try catalog.runNextBatch(
                sourceID: source.id, maximumWorkItems: 8, maximumBytes: 256 * 1_024
            )
        }
        let revisions = try catalog.revisions(sourceID: source.id)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(revisions.first?.id, secondRevision)
        XCTAssertEqual(revisions.first?.priorRevisionID, firstRevision)
        XCTAssertNotNil(revisions.first?.manifestSHA256)
    }

    func testRepositoryIdentityIsCapturedWithoutCredentialsOrGitContentTraversal() async throws {
        let fixture = try SourceFixture()
        let repository = try fixture.directory("repository")
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        let branchDirectory = gitDirectory.appendingPathComponent("refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: branchDirectory, withIntermediateDirectories: true)
        let commit = String(repeating: "a", count: 40)
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        try Data("\(commit)\n".utf8).write(to: branchDirectory.appendingPathComponent("main"))
        try Data("""
        [remote "origin"]
            url = https://owner:secret@example.com/project/repository.git
        """.utf8).write(to: gitDirectory.appendingPathComponent("config"))
        try Data("Use native frameworks.\n".utf8).write(
            to: repository.appendingPathComponent("policy.md")
        )

        let catalog = try fixture.makeCatalog()
        let source = try await catalog.add(
            selectedURL: repository,
            requestID: stableUUID(prefix: 0x45, index: 1)
        )
        try catalog.scheduleOrThrow(sourceID: source.id)
        var progress = try catalog.progress(sourceID: source.id)
        while progress.pendingWorkCount > 0 {
            progress = try catalog.runNextBatch(
                sourceID: source.id, maximumWorkItems: 16, maximumBytes: 1_048_576
            )
        }

        let revision = try XCTUnwrap(catalog.revisions(sourceID: source.id).first)
        XCTAssertEqual(revision.gitCommit, commit)
        XCTAssertEqual(revision.gitBranch, "main")
        XCTAssertEqual(revision.repositoryURL, "https://example.com/project/repository.git")
        XCTAssertNil(revision.gitDirty)
        XCTAssertEqual(revision.metadata["git_worktree_state"], "unassessed")
        XCTAssertEqual(revision.metadata["git_identity_source"], "native-git-metadata")

        let artifacts = try catalog.artifacts(revisionID: revision.id)
        let gitArtifact = try XCTUnwrap(artifacts.first { $0.relativePath == ".git" })
        XCTAssertEqual(gitArtifact.interpretationState, .metadataOnly)
        XCTAssertTrue(artifacts.contains { $0.relativePath == "policy.md" })
        XCTAssertFalse(artifacts.contains { $0.relativePath.hasPrefix(".git/") })
    }

    func testNativeStrategiesRetainSegmentsAndMetadataOnlyArtifacts() async throws {
        let fixture = try SourceFixture()
        let root = try fixture.directory("mixed")
        try Data("Use Swift and AppKit.".utf8).write(to: root.appendingPathComponent("policy.md"))
        try Data("{\"platform\":\"macOS\"}".utf8).write(to: root.appendingPathComponent("policy.json"))
        try Data("{\\rtf1\\ansi Native framework only}".utf8).write(to: root.appendingPathComponent("policy.rtf"))
        try minimalZIP(path: "policy.txt").write(to: root.appendingPathComponent("policy.zip"))
        try Data([0x00, 0xFF, 0x01, 0x80]).write(to: root.appendingPathComponent("opaque.bin"))
        try Data().write(to: root.appendingPathComponent("empty"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("external-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        let catalog = try fixture.makeCatalog()
        let source = try await catalog.add(
            selectedURL: root,
            requestID: stableUUID(prefix: 0x50, index: 1)
        )
        try catalog.scheduleOrThrow(sourceID: source.id)
        var progress = try catalog.progress(sourceID: source.id)
        var passes = 0
        while progress.pendingWorkCount > 0, passes < 100 {
            progress = try catalog.runNextBatch(
                sourceID: source.id, maximumWorkItems: 16, maximumBytes: 1_048_576
            )
            passes += 1
        }
        XCTAssertEqual(progress.pendingWorkCount, 0)
        XCTAssertEqual(progress.interpretationState, .partiallyIndexed)
        let revisionID = try XCTUnwrap(progress.revisionID)
        let artifacts = try catalog.artifacts(revisionID: revisionID)
        for name in ["policy.md", "policy.json", "policy.rtf", "policy.zip"] {
            let artifact = try XCTUnwrap(artifacts.first { $0.relativePath == name })
            XCTAssertFalse(try catalog.segments(artifactID: artifact.id).isEmpty, name)
        }
        for name in ["opaque.bin", "empty", "external-link"] {
            let artifact = try XCTUnwrap(artifacts.first { $0.relativePath == name })
            XCTAssertTrue([.metadataOnly, .indexed].contains(artifact.interpretationState), name)
        }
    }

    func testMutationReplayRemovalAndSourceEventsRemainDurable() async throws {
        let fixture = try SourceFixture()
        let file = try fixture.file("policy.txt", data: Data("policy".utf8))
        let other = try fixture.file("other.txt", data: Data("other".utf8))
        let catalog = try fixture.makeCatalog()
        let requestID = stableUUID(prefix: 0x60, index: 1)
        let first = try await catalog.add(selectedURL: file, requestID: requestID)
        let replay = try await catalog.add(selectedURL: file, requestID: requestID)
        XCTAssertEqual(first.id, replay.id)
        await XCTAssertThrowsErrorAsync {
            _ = try await catalog.add(selectedURL: other, requestID: requestID)
        }
        try catalog.scheduleOrThrow(sourceID: first.id)
        _ = try catalog.runNextBatch(sourceID: first.id, maximumWorkItems: 8)
        let revisionCount = try catalog.revisions(sourceID: first.id).count
        let removeID = stableUUID(prefix: 0x60, index: 2)
        try await catalog.remove(sourceID: first.id, requestID: removeID)
        try await catalog.remove(sourceID: first.id, requestID: removeID)
        let removed = try XCTUnwrap(catalog.sources().first { $0.id == first.id })
        XCTAssertFalse(removed.active)
        XCTAssertEqual(removed.interpretationState, .removedByUser)
        XCTAssertEqual(try catalog.revisions(sourceID: first.id).count, revisionCount)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        XCTAssertNotEqual(sqlite3_exec(handle, "DELETE FROM stj_source_events;", nil, nil, &message), SQLITE_OK)
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
    }
}

private final class SourceFixture {
    let container: URL
    let root: URL
    let database: URL
    let store: URL
    let jsonl: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-source-tests-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("selected-sources", isDirectory: true)
        let state = container.appendingPathComponent("manager-state", isDirectory: true)
        database = state.appendingPathComponent("policy.sqlite3")
        store = state.appendingPathComponent("source-store", isDirectory: true)
        jsonl = state.appendingPathComponent("policy.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: container) }

    func makeCatalog() throws -> StjornarvaldPolicySourceCatalog {
        try StjornarvaldPolicySourceCatalog(databaseURL: database, sourceStoreDirectory: store)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func symbolicLink(_ name: String, destination: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func fifo(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard Darwin.mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }
}

private func stableUUID(prefix: UInt8, index: Int) -> UUID {
    UUID(uuid: (
        prefix, 0, 0, 0, 0, 0x00, 0x40, 0x00,
        0x80, 0x00, 0, 0, 0, 0, UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)
    ))
}

private func minimalZIP(path: String) -> Data {
    let name = Data(path.utf8)
    var local = Data()
    appendLE(0x0403_4B50 as UInt32, to: &local)
    appendLE(20 as UInt16, to: &local)
    appendLE(0 as UInt16, to: &local)
    appendLE(0 as UInt16, to: &local)
    appendLE(0 as UInt16, to: &local)
    appendLE(0 as UInt16, to: &local)
    appendLE(0 as UInt32, to: &local)
    appendLE(1 as UInt32, to: &local)
    appendLE(1 as UInt32, to: &local)
    appendLE(UInt16(name.count), to: &local)
    appendLE(0 as UInt16, to: &local)
    local.append(name)
    local.append(0x61)

    var central = Data()
    appendLE(0x0201_4B50 as UInt32, to: &central)
    appendLE(0x0314 as UInt16, to: &central)
    appendLE(20 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt32, to: &central)
    appendLE(1 as UInt32, to: &central)
    appendLE(1 as UInt32, to: &central)
    appendLE(UInt16(name.count), to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(0 as UInt16, to: &central)
    appendLE(UInt32(0o100600) << 16, to: &central)
    appendLE(0 as UInt32, to: &central)
    central.append(name)

    var result = local
    let centralOffset = result.count
    result.append(central)
    appendLE(0x0605_4B50 as UInt32, to: &result)
    appendLE(0 as UInt16, to: &result)
    appendLE(0 as UInt16, to: &result)
    appendLE(1 as UInt16, to: &result)
    appendLE(1 as UInt16, to: &result)
    appendLE(UInt32(central.count), to: &result)
    appendLE(UInt32(centralOffset), to: &result)
    appendLE(0 as UInt16, to: &result)
    return result
}

private func appendLE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

private func appendLE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}

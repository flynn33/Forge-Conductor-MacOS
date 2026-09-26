import Darwin
import Foundation
import XCTest

@testable import ForgeConductorCore

final class LMStudioLinkRegistryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmstudio-link-registry-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testCreateSelectRestartRemoveAndStaleRevisionCAS() async throws {
        let registry = LMStudioLinkRegistry(storageDirectory: directory)
        let empty = try await registry.read()
        XCTAssertEqual(empty.revision, "0")
        XCTAssertTrue(empty.nodes.isEmpty)

        let node = try Self.makeNode(index: 1)
        let inserted = try await registry.upsert(node, expectedRevision: empty.revision)
        XCTAssertEqual(inserted.nodes, [node])
        XCTAssertNil(inserted.activeNodeID)
        do {
            _ = try await registry.upsert(node, expectedRevision: "0")
            XCTFail("Accepted a stale registry revision")
        } catch {
            guard case LMStudioLinkRegistryError.revisionConflict("0", inserted.revision) = error else {
                return XCTFail("Expected stale revision conflict, received \(error)")
            }
        }

        let selected = try await registry.select(node.id, expectedRevision: inserted.revision)
        XCTAssertEqual(selected.activeNodeID, node.id)
        let restarted = LMStudioLinkRegistry(storageDirectory: directory)
        let reread = try await restarted.read()
        XCTAssertEqual(reread, selected)

        let removed = try await restarted.remove(node.id, expectedRevision: selected.revision)
        XCTAssertTrue(removed.nodes.isEmpty)
        XCTAssertNil(removed.activeNodeID)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(LMStudioLinkRegistry.fileName).path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testMaximumNodesAndRevokedSelectionFailClosed() async throws {
        let registry = LMStudioLinkRegistry(storageDirectory: directory)
        var revision = "0"
        for index in 0..<LMStudioLinkLimits.maximumRetainedNodes {
            revision = try await registry.upsert(
                Self.makeNode(index: index),
                expectedRevision: revision
            ).revision
        }
        do {
            _ = try await registry.upsert(
                Self.makeNode(index: LMStudioLinkLimits.maximumRetainedNodes),
                expectedRevision: revision
            )
            XCTFail("Accepted a seventeenth retained node")
        } catch {
            XCTAssertEqual(error as? LMStudioLinkRegistryError, .nodeLimitExceeded)
        }

        let revoked = try Self.makeNode(index: 0, state: .revoked)
        let changed = try await registry.upsert(revoked, expectedRevision: revision)
        do {
            _ = try await registry.select(revoked.id, expectedRevision: changed.revision)
            XCTFail("Selected a revoked node")
        } catch {
            XCTAssertEqual(error as? LMStudioLinkRegistryError, .nodeRevoked)
        }
    }

    func testTwoRegistryOwnersHaveExactlyOneCASWinner() async throws {
        let first = LMStudioLinkRegistry(storageDirectory: directory)
        let second = LMStudioLinkRegistry(storageDirectory: directory)
        let starting = try await first.read()

        let results = await withTaskGroup(of: Result<LMStudioLinkRegistrySnapshot, Error>.self) { group in
            group.addTask {
                do { return .success(try await first.upsert(Self.makeNode(index: 1), expectedRevision: starting.revision)) }
                catch { return .failure(error) }
            }
            group.addTask {
                do { return .success(try await second.upsert(Self.makeNode(index: 2), expectedRevision: starting.revision)) }
                catch { return .failure(error) }
            }
            var values: [Result<LMStudioLinkRegistrySnapshot, Error>] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(results.filter {
            if case .failure(LMStudioLinkRegistryError.revisionConflict(_, _)) = $0 { true } else { false }
        }.count, 1)
        let final = try await first.read()
        XCTAssertEqual(final.nodes.count, 1)
    }

    func testSymlinkAndBroadPermissionsAreRejected() async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        let registryPath = directory.appendingPathComponent(LMStudioLinkRegistry.fileName)
        try FileManager.default.createSymbolicLink(at: registryPath, withDestinationURL: target)
        let registry = LMStudioLinkRegistry(storageDirectory: directory)
        do {
            _ = try await registry.read()
            XCTFail("Followed a symlinked registry")
        } catch {
            XCTAssertEqual(error as? LMStudioLinkRegistryError, .unsafeStorage)
        }

        try FileManager.default.removeItem(at: registryPath)
        let clean = LMStudioLinkRegistry(storageDirectory: directory)
        _ = try await clean.upsert(Self.makeNode(index: 1), expectedRevision: "0")
        XCTAssertEqual(Darwin.chmod(registryPath.path, 0o644), 0)
        do {
            _ = try await clean.read()
            XCTFail("Accepted a broadly readable registry")
        } catch {
            XCTAssertEqual(error as? LMStudioLinkRegistryError, .unsafeStorage)
        }
    }

    private static func makeNode(
        index: Int,
        state: LMStudioLinkNodeState = .active
    ) throws -> LMStudioLinkNodeSnapshot {
        let suffix = String(format: "%012x", index + 1)
        let id = LMStudioLinkNodeID(
            rawValue: UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
        )
        return try LMStudioLinkNodeSnapshot(
            id: id,
            displayName: "GB10 \(index)",
            origin: URL(string: "https://gb10-\(index).fixture:57400")!,
            spkiSHA256: String(repeating: "a", count: 64),
            credentialReference: "link-\(id)",
            capabilities: ["proxy", "control", "mcp-relay"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
            state: state
        )
    }
}

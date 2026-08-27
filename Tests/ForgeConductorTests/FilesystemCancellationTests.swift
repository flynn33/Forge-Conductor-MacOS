import XCTest
import Darwin
@testable import ForgeConductorCore

final class FilesystemCancellationTests: XCTestCase {
    private var home: URL!
    private var app: ForgeApp!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "filesystem-cancellation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        app = try ForgeApp.bootstrap(home: home)
    }

    override func tearDownWithError() throws {
        app.shutdown()
        app = nil
        try? FileManager.default.removeItem(at: home)
    }

    func testRecursiveDeleteReportsPartialMutationAfterCancellation() throws {
        let root = home.appendingPathComponent("delete-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data("\(index)".utf8).write(
                to: root.appendingPathComponent("item-\(index).txt")
            )
        }
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let pack = FilesystemToolPack { removedCount in
            if removedCount == 2 { cancellation.cancel() }
        }

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": root.path],
            context: nil,
            clientID: ClientID("partial-delete"),
            app: app,
            cancellation: cancellation
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "request_cancelled")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 2)
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
    }

    func testPreCancelledRecursiveDeleteLeavesTreeUntouched() throws {
        let root = home.appendingPathComponent("untouched-tree", isDirectory: true)
        let file = root.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: file)
        let cancellation = ToolCallCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(try FilesystemToolPack().handle(
            name: "fs_delete",
            arguments: ["path": root.path],
            context: nil,
            clientID: ClientID("pre-cancelled-delete"),
            app: app,
            cancellation: cancellation
        )) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecursiveDeleteDoesNotFollowChildSymlink() throws {
        let root = home.appendingPathComponent("symlink-tree", isDirectory: true)
        let outside = home.appendingPathComponent("outside.txt")
        let link = root.appendingPathComponent("outside-link")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = try XCTUnwrap(try FilesystemToolPack().handle(
            name: "fs_delete",
            arguments: ["path": root.path],
            context: nil,
            clientID: ClientID("symlink-delete"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
    }

    func testSameVolumeMoveDoesNotOverwriteExistingDestination() throws {
        let source = home.appendingPathComponent("same-volume-source.txt")
        let destination = home.appendingPathComponent("same-volume-destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        XCTAssertThrowsError(try FilesystemToolPack().handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("exclusive-same-volume-move"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("destination".utf8))
    }

    func testMissingMoveSourceDoesNotCreateDestinationHierarchy() throws {
        let source = home.appendingPathComponent("missing-source.txt")
        let first = home.appendingPathComponent("must-not-exist", isDirectory: true)
        let destination = first
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("destination.txt")

        XCTAssertThrowsError(try FilesystemToolPack().handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("missing-source-preflight"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCrossVolumeMovePublishesExactTargetAndRemovesSource() throws {
        let source = home.appendingPathComponent("cross-volume-source", isDirectory: true)
        let destination = home.appendingPathComponent("cross-volume-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("item.txt"))
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("exact-cross-volume-move"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("item.txt")),
            Data("payload".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(source.lastPathComponent).path
            )
        )
    }

    func testCrossVolumeMoveDoesNotOverwriteExistingDestination() throws {
        let source = home.appendingPathComponent("cross-volume-source.txt")
        let destination = home.appendingPathComponent("cross-volume-destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: true
        )

        XCTAssertThrowsError(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("exclusive-cross-volume-move"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("destination".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: home.path)
                .contains { $0.hasPrefix(".forge-move-") }
        )
    }

    func testCrossVolumeCancellationAfterInstallReportsBothDurableStates() throws {
        let source = home.appendingPathComponent("installed-source.txt")
        let destination = home.appendingPathComponent("installed-destination.txt")
        try Data("payload".utf8).write(to: source)
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                if step == .installedDestination { cancellation.cancel() }
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("installed-cross-volume-cancellation"),
            app: app,
            cancellation: cancellation
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "request_cancelled")
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testCrossVolumeMovePreservesSourceReplacedAfterDestinationInstall() throws {
        let source = home.appendingPathComponent("replaced-source.txt")
        let destination = home.appendingPathComponent("published-destination.txt")
        try Data("original".utf8).write(to: source)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeSourceFenceVerification else { return }
                try? FileManager.default.removeItem(at: source)
                try? Data("replacement".utf8).write(to: source)
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-source-replacement"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["source_fence_verified"] as? Bool, false)
        XCTAssertEqual(result.payload["source_preserved"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testCrossVolumeMovePreservesMetadataChangedSourceEntryAfterDeletionStarts() throws {
        let source = home.appendingPathComponent("metadata-source", isDirectory: true)
        let preserved = source.appendingPathComponent("a-preserved.txt")
        let removedFirst = source.appendingPathComponent("z-removed-first.txt")
        let destination = home.appendingPathComponent("metadata-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: preserved)
        try Data("remove".utf8).write(to: removedFirst)
        let mutation = ExtendedAttributeMutation(url: preserved)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .removedSourceEntry(1) else { return }
                mutation.apply()
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-metadata-change"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertEqual(mutation.result, 0)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertEqual(result.payload["source_fence_verified"] as? Bool, false)
        XCTAssertEqual(result.payload["source_preserved"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFirst.path))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("preserve".utf8))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a-preserved.txt")),
            Data("preserve".utf8)
        )
    }

    func testCrossVolumeMoveReconcilesMetadataChangedByRemovingSiblingHardLink() throws {
        let source = home.appendingPathComponent("hard-link-source", isDirectory: true)
        let first = source.appendingPathComponent("first.txt")
        let second = source.appendingPathComponent("second.txt")
        let destination = home.appendingPathComponent("hard-link-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)
        let reconciliation = HardLinkReconciliationCounter()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { reconciliation.observe($0) },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-hard-link-metadata"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(reconciliation.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("first.txt")),
            Data("shared".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("second.txt")),
            Data("shared".utf8)
        )
    }

    func testUniqueFileMoveBypassesHardLinkReconciliation() throws {
        let source = home.appendingPathComponent("unique-source", isDirectory: true)
        let destination = home.appendingPathComponent("unique-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<256 {
            try Data("\(index)".utf8).write(
                to: source.appendingPathComponent("item-\(index).txt")
            )
        }
        let reconciliation = HardLinkReconciliationCounter()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { reconciliation.observe($0) },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-unique-scaling"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 20)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(reconciliation.count, 0)
        XCTAssertEqual(result.payload["moved_entries"] as? Int, 257)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testCrossVolumeStagingDeadlineStopsSynchronizationAndRequiresCleanup() throws {
        let source = home.appendingPathComponent("deadline-source", isDirectory: true)
        let destination = home.appendingPathComponent("deadline-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("item.txt"))
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .synchronizingStagingEntry(1) else { return }
                try? cancellation.tightenDeadline(milliseconds: 1)
                Thread.sleep(forTimeInterval: 0.02)
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-staging-deadline"),
            app: app,
            cancellation: cancellation
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "deadline_exceeded")
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, false)
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("item.txt")),
            Data("payload".utf8)
        )
    }

    func testPostRemovalStagingDeadlineDoesNotClaimCleanupIsRequired() throws {
        let source = home.appendingPathComponent("cleanup-deadline-source.txt")
        let destination = home.appendingPathComponent("cleanup-deadline-destination.txt")
        try Data("payload".utf8).write(to: source)
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let synchronizer = FirstStagingDirectorySyncFailure()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .removedStagingEntry(1) else { return }
                try? cancellation.tightenDeadline(milliseconds: 1)
                Thread.sleep(forTimeInterval: 0.02)
            },
            forceCrossVolumeMove: true,
            directorySynchronizer: { try synchronizer.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("post-removal-staging-deadline"),
            app: app,
            cancellation: cancellation
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "deadline_exceeded")
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, false)
        XCTAssertEqual(result.payload["staging_exists"] as? Bool, false)
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMoveRenameFailureAfterCreatingParentsReportsPartialMutation() throws {
        let source = home.appendingPathComponent("rename-race-source.txt")
        let first = home.appendingPathComponent("rename-race-created", isDirectory: true)
        let second = first.appendingPathComponent("nested", isDirectory: true)
        let destination = second.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .preparedDestinationDirectories else { return }
                try? Data("competitor".utf8).write(to: destination)
            },
            forceCrossVolumeMove: false
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("rename-race-created-parents"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["created_directories"] as? [String], [first.path, second.path])
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 2)
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, false)
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("competitor".utf8))
    }

    func testCrossVolumeInstallFailureAfterCreatingParentsReportsPartialMutation() throws {
        let source = home.appendingPathComponent("install-race-source.txt")
        let first = home.appendingPathComponent("install-race-created", isDirectory: true)
        let second = first.appendingPathComponent("nested", isDirectory: true)
        let destination = second.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .copiedToStaging else { return }
                try? Data("competitor".utf8).write(to: destination)
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("install-race-created-parents"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["created_directories"] as? [String], [first.path, second.path])
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 2)
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, false)
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("competitor".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: second.path)
                .contains { $0.hasPrefix(".forge-move-") }
        )
    }

    func testMoveSynchronizesEveryCreatedParentAndBothRenameParents() throws {
        let source = home.appendingPathComponent("durable-parent-source.txt")
        let first = home.appendingPathComponent("created-first", isDirectory: true)
        let second = first.appendingPathComponent("created-second", isDirectory: true)
        let destination = second.appendingPathComponent("destination.txt")
        try Data("payload".utf8).write(to: source)
        let recorder = DirectorySyncRecorder()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: false,
            directorySynchronizer: { try recorder.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("durable-move-parents"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, true)
        XCTAssertEqual(
            recorder.paths,
            [first.path, home.path, second.path, first.path, second.path, home.path]
        )
        for directory in [first, second] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testDestinationHierarchySyncFailureReportsCreatedDirectory() throws {
        let source = home.appendingPathComponent("hierarchy-failure-source.txt")
        let first = home.appendingPathComponent("created-before-failure", isDirectory: true)
        let destination = first
            .appendingPathComponent("not-created", isDirectory: true)
            .appendingPathComponent("destination.txt")
        try Data("payload".utf8).write(to: source)
        let recorder = DirectorySyncRecorder(failingPath: first.path)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: false,
            directorySynchronizer: { try recorder.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("durable-hierarchy-failure"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertEqual(result.payload["created_directories"] as? [String], [first.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
    }

    func testSameParentMoveSynchronizesParentOnce() throws {
        let source = home.appendingPathComponent("deduplicated-source.txt")
        let destination = home.appendingPathComponent("deduplicated-destination.txt")
        try Data("payload".utf8).write(to: source)
        let recorder = DirectorySyncRecorder()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: false,
            directorySynchronizer: { try recorder.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("deduplicated-move-parent"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(recorder.paths, [home.path])
    }

    func testPostRenameSynchronizationFailureReturnsCommittedMove() throws {
        let sourceParent = home.appendingPathComponent("source-parent", isDirectory: true)
        let destinationParent = home.appendingPathComponent("destination-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let source = sourceParent.appendingPathComponent("source.txt")
        let destination = destinationParent.appendingPathComponent("destination.txt")
        try Data("payload".utf8).write(to: source)
        let recorder = DirectorySyncRecorder(failingPath: sourceParent.path)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: false,
            directorySynchronizer: { try recorder.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("committed-move-sync-failure"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        XCTAssertNotNil(result.payload["durability_error"] as? String)
        XCTAssertEqual(recorder.paths, [destinationParent.path, sourceParent.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testCrossVolumeSourceParentSyncFailureReturnsCommittedMove() throws {
        let sourceParent = home.appendingPathComponent("cross-source-parent", isDirectory: true)
        let destinationParent = home.appendingPathComponent("cross-destination-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let source = sourceParent.appendingPathComponent("source.txt")
        let destination = destinationParent.appendingPathComponent("destination.txt")
        try Data("payload".utf8).write(to: source)
        let recorder = DirectorySyncRecorder(failingPath: sourceParent.path)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: true,
            directorySynchronizer: { try recorder.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("committed-cross-volume-sync-failure"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
        XCTAssertTrue(recorder.paths.contains(destinationParent.path))
        XCTAssertEqual(recorder.paths.last, sourceParent.path)
    }
}

private final class DirectorySyncRecorder: @unchecked Sendable {
    enum InjectedFailure: Error { case synchronize }

    private let lock = NSLock()
    private var recordedPaths: [String] = []
    private let failingPath: String?

    init(failingPath: String? = nil) {
        self.failingPath = failingPath
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func synchronize(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        lock.lock()
        recordedPaths.append(path)
        lock.unlock()
        if path == failingPath { throw InjectedFailure.synchronize }
    }
}

private final class ExtendedAttributeMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var storedResult: Int32?

    init(url: URL) {
        self.url = url
    }

    var result: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func apply() {
        let value = Data("changed".utf8)
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                "com.forge.metadata-fence".withCString { name in
                    Darwin.setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        lock.lock()
        storedResult = result
        lock.unlock()
    }
}

private final class HardLinkReconciliationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func observe(_ step: FilesystemToolPack.MoveStep) {
        guard step == .reconcilingHardLinkGroup else { return }
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}

private final class FirstStagingDirectorySyncFailure: @unchecked Sendable {
    enum InjectedFailure: Error { case synchronize }

    private let lock = NSLock()
    private var failed = false

    func synchronize(_ directory: URL) throws {
        let isStaging = directory.lastPathComponent.hasPrefix(".forge-move-")
        lock.lock()
        let shouldFail = isStaging && !failed
        if shouldFail { failed = true }
        lock.unlock()
        if shouldFail { throw InjectedFailure.synchronize }
    }
}

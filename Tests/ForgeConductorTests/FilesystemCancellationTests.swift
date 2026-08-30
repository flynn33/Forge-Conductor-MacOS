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

        XCTAssertThrowsError(try FilesystemToolPack(deletionStepObserver: nil).handle(
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

        let result = try XCTUnwrap(try FilesystemToolPack(deletionStepObserver: nil).handle(
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

    func testRecursiveDeletePinsIntermediateParentBeforeUnlink() throws {
        let root = home.appendingPathComponent("pinned-delete-tree", isDirectory: true)
        let branch = root.appendingPathComponent("branch", isDirectory: true)
        let relocatedBranch = root.appendingPathComponent("branch-original", isDirectory: true)
        let item = branch.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: item)
        let mutation = DirectorySwapMutation(
            originalParent: branch,
            relocatedParent: relocatedBranch,
            replacementName: item.lastPathComponent,
            replacementData: Data("replacement".utf8)
        )
        let pack = FilesystemToolPack(deletionMutationObserver: { step in
            guard step == .beforeRemoving("branch/item.txt") else { return }
            mutation.apply()
        })

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": root.path],
            context: nil,
            clientID: ClientID("pinned-delete-parent"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: branch.appendingPathComponent("item.txt")), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedBranch.appendingPathComponent("item.txt").path))
    }

    func testRecursiveDeletePreservesLeafSwappedAfterVerification() throws {
        let root = home.appendingPathComponent("leaf-race-delete", isDirectory: true)
        let victim = root.appendingPathComponent("a-victim.txt")
        let removedFirst = root.appendingPathComponent("z-removed-first.txt")
        let peer = home.appendingPathComponent("delete-peer.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: victim)
        try Data("first".utf8).write(to: removedFirst)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let pack = FilesystemToolPack(deletionMutationObserver: { step in
            guard step == .afterVerifying("a-victim.txt") else { return }
            mutation.apply(to: victim)
        })

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": root.path],
            context: nil,
            clientID: ClientID("delete-leaf-race"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        let quarantine = try XCTUnwrap(retainedQuarantineURL(in: root))
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFirst.path))
    }

    func testInitialQuarantineSyncFailureReportsRetainedTransitionWithoutRollback() throws {
        let parent = home.appendingPathComponent("quarantine-sync-failure", isDirectory: true)
        let victim = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("preserve-for-recovery".utf8).write(to: victim)
        let pack = FilesystemToolPack(
            deletionMutationObserver: nil,
            quarantineDirectorySynchronizer: { _, path in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [NSFilePathErrorKey: path.path]
                )
            }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("quarantine-sync-failure"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "quarantine_transition_retained")
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["namespace_mutated"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testDeleteReportsUnknownPresenceWithoutFalseExistenceClaim() throws {
        let parent = home.appendingPathComponent("unknown-presence-parent", isDirectory: true)
        let relocatedParent = home.appendingPathComponent(
            "unknown-presence-parent-relocated",
            isDirectory: true
        )
        let victim = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("delete-me".utf8).write(to: victim)
        let mutation = ParentBecomesFileMutation(
            parent: parent,
            relocatedParent: relocatedParent
        )
        let pack = FilesystemToolPack { removedCount in
            guard removedCount == 1 else { return }
            mutation.apply()
        }

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("unknown-presence-delete"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertTrue(result.payload["source_exists"] is NSNull)
        XCTAssertEqual(result.payload["source_presence_known"] as? Bool, false)
    }

    func testRollbackRefusesSubstitutedQuarantineOccupant() throws {
        let parent = home.appendingPathComponent("rollback-identity-parent", isDirectory: true)
        let victim = parent.appendingPathComponent("victim.txt")
        let peer = home.appendingPathComponent("rollback-identity-peer.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: victim)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let pack = FilesystemToolPack(deletionMutationObserver: { step in
            guard case .afterQuarantining(let quarantinePath) = step else { return }
            mutation.apply(to: URL(fileURLWithPath: quarantinePath))
        })

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("rollback-refuses-substitution"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["namespace_mutated"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        let quarantinePath = try XCTUnwrap(mutation.targetPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: quarantinePath)),
            Data("replacement".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
    }

    func testUnavailableQuarantineLedgerFailsClosedBeforeNamespaceMutation() throws {
        let victim = home.appendingPathComponent("ledger-unavailable-victim.txt")
        try Data("preserve".utf8).write(to: victim)
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        try FileManager.default.removeItem(at: ledgerRoot)
        try Data("not-a-directory".utf8).write(to: ledgerRoot)

        let result = try XCTUnwrap(try FilesystemToolPack(deletionStepObserver: nil).handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("ledger-unavailable"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "quarantine_unavailable")
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["namespace_mutated"] as? Bool, false)
        XCTAssertNil(result.payload["recovery_path"])
        XCTAssertEqual(try Data(contentsOf: victim), Data("preserve".utf8))
    }

    func testPostUnlinkReceiptSyncFailureDoesNotClaimMissingRecoveryPath() throws {
        let ledgerRoot = home.appendingPathComponent(
            "receipt-unlink-sync-ledger",
            isDirectory: true
        )
        let parent = home.appendingPathComponent("receipt-unlink-sync-parent", isDirectory: true)
        let source = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source)
        let remover = PostUnlinkReceiptRemovalFailure()
        let ledger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "post-unlink-sync-failure",
            receiptRemover: { try remover.remove($0) }
        )
        let reservation = try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_post_unlink_sync_failure"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }

        let terminal = try ledger.performTerminal(reservation) {
            try FileManager.default.removeItem(at: reservation.quarantineURL)
            return (value: (), durabilityConfirmed: true)
        }

        XCTAssertTrue(terminal.durabilityConfirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.receiptURL.path))
        XCTAssertEqual(try ledger.reconcile(), [])

        try Data("second".utf8).write(to: source)
        let next = try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_slot_reuse_after_unlink"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        XCTAssertEqual(next.slot, reservation.slot)
    }

    func testReceiptRemovalFailureRetainsTerminalRecoveryPath() throws {
        let ledgerRoot = home.appendingPathComponent(
            "receipt-retained-ledger",
            isDirectory: true
        )
        let parent = home.appendingPathComponent("receipt-retained-parent", isDirectory: true)
        let source = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source)
        let remover = ReceiptRemovalFailureWithoutUnlink()
        let ledger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "receipt-remains-after-failure",
            receiptRemover: { try remover.remove($0) }
        )
        let reservation = try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_receipt_retained"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }

        let terminal = try ledger.performTerminal(reservation) {
            try FileManager.default.removeItem(at: reservation.quarantineURL)
            return (value: (), durabilityConfirmed: true)
        }

        XCTAssertFalse(terminal.durabilityConfirmed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.receiptURL.path))
        XCTAssertEqual(try ledger.reconcile(), [reservation.receiptURL.path])
    }

    func testDeleteQuarantineIsGloballyBoundedAndRecoveredAcrossRestart() throws {
        XCTAssertEqual(FilesystemQuarantineLedger.maximumReservations, 32)
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let firstLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "before-restart"
        )
        var interrupted: [FilesystemQuarantineReservation] = []
        for index in 0..<FilesystemQuarantineLedger.maximumReservations {
            let parent = home.appendingPathComponent("interrupted-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let source = parent.appendingPathComponent("victim.txt")
            try Data("pending-\(index)".utf8).write(to: source)
            let reservation = try firstLedger.reserveAndQuarantine(
                parent: parent,
                originalName: source.lastPathComponent,
                parentIdentity: try quarantineIdentity(at: parent),
                leafIdentity: try quarantineIdentity(at: source),
                operation: "test_interruption"
            ) { reservation in
                try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
            }
            interrupted.append(reservation)
        }

        let restartedLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "after-restart"
        )
        let expectedRecoveryPaths = interrupted.map(\.quarantineURL.path)
        XCTAssertEqual(Set(try restartedLedger.reconcile()), Set(expectedRecoveryPaths))

        let parent = home.appendingPathComponent("capacity-blocked", isDirectory: true)
        let victim = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: victim)

        let result = try XCTUnwrap(try FilesystemToolPack(deletionStepObserver: nil).handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("delete-quarantine-capacity"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "quarantine_capacity_exhausted")
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        XCTAssertTrue(expectedRecoveryPaths.contains(result.payload["recovery_path"] as? String ?? ""))
        XCTAssertEqual(
            Set(result.payload["recovery_paths"] as? [String] ?? []),
            Set(expectedRecoveryPaths)
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("preserve".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .contains { $0.hasPrefix(".forge-quarantine-") }
        )

        let recovered = interrupted[0]
        try FileManager.default.moveItem(at: recovered.quarantineURL, to: recovered.originalURL)
        XCTAssertEqual(try restartedLedger.reconcile().count, expectedRecoveryPaths.count - 1)
        let retry = try XCTUnwrap(try FilesystemToolPack(deletionStepObserver: nil).handle(
            name: "fs_delete",
            arguments: ["path": victim.path],
            context: nil,
            clientID: ClientID("delete-after-quarantine-recovery"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))
        XCTAssertTrue(retry.ok, "\(retry.payload)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    func testCorruptQuarantineReceiptRemainsOccupiedAndRecoveryVisible() throws {
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let firstLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "corrupt-receipt-writer"
        )
        let firstParent = home.appendingPathComponent("corrupt-receipt-parent", isDirectory: true)
        let firstSource = firstParent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try Data("preserve-for-recovery".utf8).write(to: firstSource)
        let corruptReservation = try firstLedger.reserveAndQuarantine(
            parent: firstParent,
            originalName: firstSource.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: firstParent),
            leafIdentity: try quarantineIdentity(at: firstSource),
            operation: "test_corrupt_receipt"
        ) { reservation in
            try FileManager.default.moveItem(at: firstSource, to: reservation.quarantineURL)
        }
        try Data("{not-a-valid-receipt".utf8).write(to: corruptReservation.receiptURL)

        let restartedLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "corrupt-receipt-reader"
        )
        XCTAssertEqual(try restartedLedger.reconcile(), [corruptReservation.receiptURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptReservation.receiptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptReservation.quarantineURL.path))

        let secondParent = home.appendingPathComponent("after-corrupt-receipt", isDirectory: true)
        let secondSource = secondParent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: secondSource)
        let secondReservation = try restartedLedger.reserveAndQuarantine(
            parent: secondParent,
            originalName: secondSource.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: secondParent),
            leafIdentity: try quarantineIdentity(at: secondSource),
            operation: "test_corrupt_receipt_next_slot"
        ) { reservation in
            try FileManager.default.moveItem(at: secondSource, to: reservation.quarantineURL)
        }

        XCTAssertNotEqual(secondReservation.slot, corruptReservation.slot)
        XCTAssertEqual(secondReservation.slot, corruptReservation.slot + 1)
        XCTAssertEqual(
            Set(try restartedLedger.reconcile()),
            Set([corruptReservation.receiptURL.path, secondReservation.quarantineURL.path])
        )
    }

    func testPreexistingDeterministicQuarantineNameIsNotClaimed() throws {
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let ledger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "preexisting-quarantine"
        )
        let parent = home.appendingPathComponent("preexisting-quarantine-parent", isDirectory: true)
        let source = parent.appendingPathComponent("victim.txt")
        let existingQuarantine = parent.appendingPathComponent(".forge-quarantine-v1-00")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try Data("preexisting".utf8).write(to: existingQuarantine)

        XCTAssertThrowsError(try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_preexisting_quarantine"
        ) { reservation in
            let result = source.path.withCString { sourcePath in
                reservation.quarantineURL.path.withCString { quarantinePath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        quarantinePath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EEXIST))
        }

        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: existingQuarantine), Data("preexisting".utf8))
        XCTAssertEqual(try ledger.reconcile(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ledgerRoot.appendingPathComponent("slot-00.json").path
        ))
    }

    func testStaleQuarantineReservationCannotReleaseReusedSlot() throws {
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let parent = home.appendingPathComponent("stale-reservation-parent", isDirectory: true)
        let source = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source)
        let firstLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "stale-reservation-first"
        )
        let staleReservation = try firstLedger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_stale_reservation_first"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        _ = try firstLedger.performTerminal(staleReservation) {
            try FileManager.default.moveItem(
                at: staleReservation.quarantineURL,
                to: staleReservation.originalURL
            )
            return (value: (), durabilityConfirmed: true)
        }

        let secondLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "stale-reservation-second"
        )
        let currentReservation = try secondLedger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_stale_reservation_second"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        XCTAssertEqual(currentReservation.slot, staleReservation.slot)
        XCTAssertNotEqual(currentReservation.identifier, staleReservation.identifier)

        let unconfirmed = try secondLedger.performTerminal(currentReservation) {
            try FileManager.default.moveItem(
                at: currentReservation.quarantineURL,
                to: currentReservation.originalURL
            )
            return (value: (), durabilityConfirmed: false)
        }
        XCTAssertFalse(unconfirmed.durabilityConfirmed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentReservation.receiptURL.path))

        try firstLedger.releaseRestoredReservation(staleReservation)

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentReservation.receiptURL.path))
        try secondLedger.releaseRestoredReservation(currentReservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentReservation.receiptURL.path))
    }

    func testRestartDoesNotTreatMissingNamesAsTerminalProof() throws {
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let parent = home.appendingPathComponent("missing-names-parent", isDirectory: true)
        let source = parent.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("terminal-but-unconfirmed".utf8).write(to: source)
        let firstLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "missing-names-first"
        )
        let reservation = try firstLedger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "test_unconfirmed_terminal"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        let terminal = try firstLedger.performTerminal(reservation) {
            try FileManager.default.removeItem(at: reservation.quarantineURL)
            return (value: (), durabilityConfirmed: false)
        }
        XCTAssertFalse(terminal.durabilityConfirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.quarantineURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.receiptURL.path))

        let restartedLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "missing-names-second"
        )
        XCTAssertEqual(try restartedLedger.reconcile(), [reservation.receiptURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.receiptURL.path))
    }

    func testConcurrentQuarantineReservationsNeverExceedGlobalCapacity() throws {
        let ledgerRoot = app.paths.home.appendingPathComponent(
            "filesystem-quarantine",
            isDirectory: true
        )
        let attemptCount = FilesystemQuarantineLedger.maximumReservations + 8
        var attempts: [QuarantineReservationAttempt] = []
        for index in 0..<attemptCount {
            let parent = home.appendingPathComponent("concurrent-quarantine-\(index)", isDirectory: true)
            let source = parent.appendingPathComponent("victim.txt")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("concurrent-\(index)".utf8).write(to: source)
            attempts.append(QuarantineReservationAttempt(
                parent: parent,
                source: source,
                parentIdentity: try quarantineIdentity(at: parent),
                leafIdentity: try quarantineIdentity(at: source)
            ))
        }
        let results = QuarantineReservationResults()
        let reservationAttempts = attempts

        DispatchQueue.concurrentPerform(iterations: reservationAttempts.count) { index in
            let attempt = reservationAttempts[index]
            let ledger = FilesystemQuarantineLedger(
                root: ledgerRoot,
                processInstanceID: "concurrent-reservation-\(index)"
            )
            do {
                let reservation = try ledger.reserveAndQuarantine(
                    parent: attempt.parent,
                    originalName: attempt.source.lastPathComponent,
                    parentIdentity: attempt.parentIdentity,
                    leafIdentity: attempt.leafIdentity,
                    operation: "test_concurrent_reservation"
                ) { reservation in
                    try FileManager.default.moveItem(
                        at: attempt.source,
                        to: reservation.quarantineURL
                    )
                }
                results.record(reservation: reservation)
            } catch {
                results.record(error: error)
            }
        }

        let snapshot = results.snapshot
        XCTAssertEqual(
            snapshot.reservations.count,
            FilesystemQuarantineLedger.maximumReservations
        )
        XCTAssertEqual(
            Set(snapshot.reservations.map(\.slot)).count,
            snapshot.reservations.count
        )
        XCTAssertEqual(snapshot.capacityFailures, attemptCount - FilesystemQuarantineLedger.maximumReservations)
        XCTAssertEqual(snapshot.lockTimeouts, 0)
        XCTAssertTrue(snapshot.unexpectedErrors.isEmpty, "\(snapshot.unexpectedErrors)")

        let restartedLedger = FilesystemQuarantineLedger(
            root: ledgerRoot,
            processInstanceID: "concurrent-reservation-restart"
        )
        XCTAssertEqual(
            Set(try restartedLedger.reconcile()),
            Set(snapshot.reservations.map(\.quarantineURL.path))
        )
    }

    func testSameVolumeMoveDoesNotOverwriteExistingDestination() throws {
        let source = home.appendingPathComponent("same-volume-source.txt")
        let destination = home.appendingPathComponent("same-volume-destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        XCTAssertThrowsError(try FilesystemToolPack(deletionStepObserver: nil).handle(
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

    func testSameVolumeMoveRejectsReboundSourceParent() throws {
        let sourceParent = home.appendingPathComponent("same-volume-source-parent", isDirectory: true)
        let relocatedParent = home.appendingPathComponent("same-volume-source-original", isDirectory: true)
        let source = sourceParent.appendingPathComponent("source.txt")
        let destination = home.appendingPathComponent("same-volume-pinned-destination.txt")
        try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let mutation = DirectorySwapMutation(
            originalParent: sourceParent,
            relocatedParent: relocatedParent,
            replacementName: source.lastPathComponent,
            replacementData: Data("replacement".utf8)
        )
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeSameVolumeRename else { return }
                mutation.apply()
            },
            forceCrossVolumeMove: false
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("pinned-same-volume-parent"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(
            try Data(contentsOf: relocatedParent.appendingPathComponent("source.txt")),
            Data("original".utf8)
        )
    }

    func testSameVolumeMoveRejectsReboundDestinationParent() throws {
        let source = home.appendingPathComponent("same-volume-destination-race-source.txt")
        let destinationParent = home.appendingPathComponent("same-volume-destination-parent", isDirectory: true)
        let relocatedParent = home.appendingPathComponent("same-volume-destination-original", isDirectory: true)
        let destination = destinationParent.appendingPathComponent("destination.txt")
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let mutation = DirectorySwapMutation(
            originalParent: destinationParent,
            relocatedParent: relocatedParent,
            replacementName: "replacement.txt",
            replacementData: Data("replacement".utf8)
        )
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeSameVolumeRename else { return }
                mutation.apply()
            },
            forceCrossVolumeMove: false
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("rebound-same-volume-destination"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedParent.appendingPathComponent("destination.txt").path))
    }

    func testSameVolumeCancellationBeforeRenamePreservesSource() throws {
        let source = home.appendingPathComponent("cancelled-same-volume-source.txt")
        let destination = home.appendingPathComponent("cancelled-same-volume-destination.txt")
        try Data("original".utf8).write(to: source)
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeSameVolumeRename else { return }
                cancellation.cancel()
            },
            forceCrossVolumeMove: false
        )

        XCTAssertThrowsError(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cancel-before-same-volume-rename"),
            app: app,
            cancellation: cancellation
        )) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSameVolumeMoveDoesNotPublishLeafSwappedAfterVerification() throws {
        let source = home.appendingPathComponent("same-volume-leaf-race-source.txt")
        let destination = home.appendingPathComponent("same-volume-leaf-race-destination.txt")
        let peer = home.appendingPathComponent("same-volume-leaf-race-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .afterVerifyingSameVolumeSource else { return }
                mutation.apply(to: source)
            },
            forceCrossVolumeMove: false
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("same-volume-leaf-race"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let quarantine = try XCTUnwrap(retainedQuarantineURL(in: home))
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSameVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt() throws {
        let source = home.appendingPathComponent("same-volume-unstable-source.txt")
        let destination = home.appendingPathComponent("same-volume-unstable-destination.txt")
        let peer = home.appendingPathComponent("same-volume-unstable-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let failure = ArmedDirectorySyncFailure()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .afterPublishingSameVolumeDestination else { return }
                mutation.apply(to: destination)
                failure.arm()
            },
            forceCrossVolumeMove: false,
            directorySynchronizer: { try failure.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("same-volume-unstable-durability"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["requested_namespace_stable"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertEqual(result.payload["recovery_paths"] as? [String], [recoveryPath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
    }

    func testMissingMoveSourceDoesNotCreateDestinationHierarchy() throws {
        let source = home.appendingPathComponent("missing-source.txt")
        let first = home.appendingPathComponent("must-not-exist", isDirectory: true)
        let destination = first
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("destination.txt")

        XCTAssertThrowsError(try FilesystemToolPack(deletionStepObserver: nil).handle(
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

    func testCrossVolumeMoveRejectsSourceReplacedBeforeFenceCapture() throws {
        let source = home.appendingPathComponent("pre-fence-replaced-source.txt")
        let destination = home.appendingPathComponent("pre-fence-destination.txt")
        try Data("original".utf8).write(to: source)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .preparedDestinationDirectories else { return }
                try? FileManager.default.removeItem(at: source)
                try? Data("replacement".utf8).write(to: source)
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("pre-fence-source-replacement"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCrossVolumeInstallDoesNotPublishStagingLeafSwappedAfterVerification() throws {
        let source = home.appendingPathComponent("staging-leaf-race-source.txt")
        let destination = home.appendingPathComponent("staging-leaf-race-destination.txt")
        let peer = home.appendingPathComponent("staging-leaf-race-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard case .afterVerifyingStagingPayload(let stagingPath) = step else { return }
                mutation.apply(to: URL(fileURLWithPath: stagingPath))
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("staging-leaf-race"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, false)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, false)
        XCTAssertEqual(result.payload["staging_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, true)
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCrossVolumeNamespaceInstabilityWithUnconfirmedDurabilityRetainsRecoveryReceipt() throws {
        let source = home.appendingPathComponent("cross-volume-unstable-source.txt")
        let destination = home.appendingPathComponent("cross-volume-unstable-destination.txt")
        let peer = home.appendingPathComponent("cross-volume-unstable-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let failure = ArmedDirectorySyncFailure()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .afterPublishingStagingPayload else { return }
                mutation.apply(to: destination)
                failure.arm()
            },
            forceCrossVolumeMove: true,
            directorySynchronizer: { try failure.synchronize($0) }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-unstable-durability"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["requested_namespace_stable"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertEqual(result.payload["recovery_paths"] as? [String], [recoveryPath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
    }

    func testCrossVolumeNamespaceInstabilityMergesInstallAndStagingRecoveryReceipts() throws {
        let source = home.appendingPathComponent("cross-volume-two-receipt-source.txt")
        let destination = home.appendingPathComponent("cross-volume-two-receipt-destination.txt")
        let peer = home.appendingPathComponent("cross-volume-two-receipt-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let failure = ArmedDirectorySyncFailure()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .afterPublishingStagingPayload else { return }
                mutation.apply(to: destination)
                failure.arm()
            },
            forceCrossVolumeMove: true,
            directorySynchronizer: { try failure.synchronize($0) },
            quarantineDirectorySynchronizer: { _, path in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [NSFilePathErrorKey: path.path]
                )
            }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cross-volume-two-receipt-recovery"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["committed"] as? Bool, true)
        XCTAssertEqual(result.payload["requested_namespace_stable"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPaths = try XCTUnwrap(result.payload["recovery_paths"] as? [String])
        XCTAssertEqual(recoveryPaths.count, 2)
        XCTAssertEqual(result.payload["recovery_path"] as? String, recoveryPaths.first)
        XCTAssertTrue(recoveryPaths.allSatisfy(FileManager.default.fileExists(atPath:)))
        XCTAssertNotNil(result.payload["staging_cleanup_error"] as? String)
        XCTAssertEqual(result.payload["staging_exists"] as? Bool, false)
        XCTAssertEqual(result.payload["staging_presence_known"] as? Bool, true)
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, false)
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
    }

    func testCrossVolumeMoveRejectsReboundDestinationParentAndCleansPinnedStaging() throws {
        let source = home.appendingPathComponent("cross-volume-destination-race-source.txt")
        let destinationParent = home.appendingPathComponent("cross-volume-destination-parent", isDirectory: true)
        let relocatedParent = home.appendingPathComponent("cross-volume-destination-original", isDirectory: true)
        let destination = destinationParent.appendingPathComponent("destination.txt")
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let mutation = DirectorySwapMutation(
            originalParent: destinationParent,
            relocatedParent: relocatedParent,
            replacementName: "replacement.txt",
            replacementData: Data("replacement".utf8)
        )
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeDestinationInstall else { return }
                mutation.apply()
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("rebound-cross-volume-destination"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "source_changed")
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedParent.appendingPathComponent("destination.txt").path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationParent.path)
                .contains { $0.hasPrefix(".forge-move-") }
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: relocatedParent.path)
                .contains { $0.hasPrefix(".forge-move-") }
        )
    }

    func testCrossVolumeCancellationBeforeInstallPreservesSourceAndReportsStaging() throws {
        let source = home.appendingPathComponent("cancelled-cross-volume-source.txt")
        let destination = home.appendingPathComponent("cancelled-cross-volume-destination.txt")
        try Data("original".utf8).write(to: source)
        let cancellation = ToolCallCancellation(timeoutSeconds: 5)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeDestinationInstall else { return }
                cancellation.cancel()
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("cancel-before-cross-volume-install"),
            app: app,
            cancellation: cancellation
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["control_code"] as? String, "request_cancelled")
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, false)
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingPath))
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

    func testCrossVolumeSourceRemovalPreservesLeafSwappedAfterVerification() throws {
        let source = home.appendingPathComponent("source-removal-leaf-race.txt")
        let destination = home.appendingPathComponent("source-removal-leaf-race-destination.txt")
        let peer = home.appendingPathComponent("source-removal-leaf-race-peer.txt")
        try Data("original".utf8).write(to: source)
        try Data("replacement".utf8).write(to: peer)
        let mutation = AtomicLeafSwapMutation(peer: peer)
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .afterVerifyingSourceEntry(".") else { return }
                mutation.apply(to: source)
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("source-removal-leaf-race"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 0)
        XCTAssertEqual(result.payload["source_fence_verified"] as? Bool, false)
        XCTAssertEqual(result.payload["source_preserved"] as? Bool, false)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let quarantine = try XCTUnwrap(retainedQuarantineURL(in: home))
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: peer), Data("original".utf8))
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

    func testCrossVolumeRemovalPinsIntermediateSourceParent() throws {
        let source = home.appendingPathComponent("pinned-cross-source", isDirectory: true)
        let branch = source.appendingPathComponent("branch", isDirectory: true)
        let relocatedBranch = source.appendingPathComponent("branch-original", isDirectory: true)
        let item = branch.appendingPathComponent("item.txt")
        let destination = home.appendingPathComponent("pinned-cross-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: item)
        let mutation = DirectorySwapMutation(
            originalParent: branch,
            relocatedParent: relocatedBranch,
            replacementName: item.lastPathComponent,
            replacementData: Data("replacement".utf8)
        )
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: { step in
                guard step == .beforeSourceEntryRemoval("branch/item.txt") else { return }
                mutation.apply()
            },
            forceCrossVolumeMove: true
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("pinned-cross-volume-parent"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertNil(mutation.error)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["control_code"] as? String, "source_changed")
        XCTAssertEqual(result.payload["completed_entries"] as? Int, 1)
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: branch.appendingPathComponent("item.txt")), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedBranch.appendingPathComponent("item.txt").path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("branch/item.txt")), Data("original".utf8))
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

    func testPostPublicationStagingFailurePreservesRecoveryAndUnknownPresence() throws {
        let source = home.appendingPathComponent("post-publication-cleanup-source.txt")
        let destination = home.appendingPathComponent("post-publication-cleanup-destination.txt")
        try Data("payload".utf8).write(to: source)
        let failure = QuarantineSyncFailureWithInvalidatedDescriptor()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: true,
            directorySynchronizer: { _ in },
            quarantineDirectorySynchronizer: { descriptor, path in
                try failure.fail(descriptor: descriptor, path: path)
            }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("post-publication-cleanup-recovery"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(
            result.payload["control_code"] as? String,
            "quarantine_transition_retained"
        )
        XCTAssertEqual(result.payload["destination_complete"] as? Bool, true)
        XCTAssertEqual(result.payload["destination_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["source_exists"] as? Bool, true)
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["namespace_mutated"] as? Bool, true)
        XCTAssertEqual(result.payload["rollback_attempted"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, false)
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, true)
        XCTAssertTrue(result.payload["staging_exists"] is NSNull)
        XCTAssertEqual(result.payload["staging_presence_known"] as? Bool, false)
        XCTAssertNotNil(result.payload["staging_cleanup_error"] as? String)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: result.payload))
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testRetainedStagingRecoveryDoesNotClaimAbsentStagingPathNeedsCleanup() throws {
        let source = home.appendingPathComponent("absent-staging-source.txt")
        let destination = home.appendingPathComponent("absent-staging-destination.txt")
        try Data("payload".utf8).write(to: source)
        let synchronizer = FirstStagingDirectorySyncFailure()
        let pack = FilesystemToolPack(
            deletionStepObserver: nil,
            moveStepObserver: nil,
            forceCrossVolumeMove: true,
            directorySynchronizer: { try synchronizer.synchronize($0) },
            quarantineDirectorySynchronizer: { _, path in
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EIO),
                    userInfo: [NSFilePathErrorKey: path.path]
                )
            }
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: nil,
            clientID: ClientID("absent-staging-recovery"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "partial_filesystem_mutation")
        XCTAssertEqual(
            result.payload["control_code"] as? String,
            "quarantine_transition_retained"
        )
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        let recoveryPath = try XCTUnwrap(result.payload["recovery_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath))
        let stagingPath = try XCTUnwrap(result.payload["staging_path"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath))
        XCTAssertEqual(result.payload["staging_exists"] as? Bool, false)
        XCTAssertEqual(result.payload["staging_presence_known"] as? Bool, true)
        XCTAssertEqual(result.payload["staging_cleanup_required"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
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
        XCTAssertEqual(result.payload["ledger_cleanup_required"] as? Bool, true)
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        XCTAssertNotNil(result.payload["recovery_path"] as? String)
        XCTAssertNil(result.payload["rollback_attempted"])
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
        XCTAssertNil(result.payload["rollback_attempted"])
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

private final class ArmedDirectorySyncFailure: @unchecked Sendable {
    enum InjectedFailure: Error { case synchronize }

    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func synchronize(_ directory: URL) throws {
        lock.lock()
        let shouldFail = armed
        lock.unlock()
        if shouldFail { throw InjectedFailure.synchronize }
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

private final class PostUnlinkReceiptRemovalFailure: @unchecked Sendable {
    enum InjectedFailure: Error { case synchronize }

    func remove(_ receipt: URL) throws {
        try FileManager.default.removeItem(at: receipt)
        throw InjectedFailure.synchronize
    }
}

private final class ReceiptRemovalFailureWithoutUnlink: @unchecked Sendable {
    enum InjectedFailure: Error { case remove }

    func remove(_ receipt: URL) throws {
        guard FileManager.default.fileExists(atPath: receipt.path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSFilePathErrorKey: receipt.path]
            )
        }
        throw InjectedFailure.remove
    }
}

private final class QuarantineSyncFailureWithInvalidatedDescriptor: @unchecked Sendable {
    enum InjectedFailure: Error { case synchronize }

    func fail(descriptor: Int32, path: URL) throws {
        let replacement = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard replacement >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path.path]
            )
        }
        defer { _ = Darwin.close(replacement) }
        guard Darwin.dup2(replacement, descriptor) >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path.path]
            )
        }
        throw InjectedFailure.synchronize
    }
}

private func quarantineIdentity(at url: URL) throws -> FilesystemQuarantineIdentity {
    var information = stat()
    guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
    return FilesystemQuarantineIdentity(information)
}

private func retainedQuarantineURL(in parent: URL) throws -> URL? {
    try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: nil,
        options: []
    ).first { $0.lastPathComponent.hasPrefix(".forge-quarantine-v1-") }
}

private struct QuarantineReservationAttempt: Sendable {
    let parent: URL
    let source: URL
    let parentIdentity: FilesystemQuarantineIdentity
    let leafIdentity: FilesystemQuarantineIdentity
}

private final class QuarantineReservationResults: @unchecked Sendable {
    struct Snapshot {
        let reservations: [FilesystemQuarantineReservation]
        let capacityFailures: Int
        let lockTimeouts: Int
        let unexpectedErrors: [String]
    }

    private let lock = NSLock()
    private var reservations: [FilesystemQuarantineReservation] = []
    private var capacityFailures = 0
    private var lockTimeouts = 0
    private var unexpectedErrors: [String] = []

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            reservations: reservations,
            capacityFailures: capacityFailures,
            lockTimeouts: lockTimeouts,
            unexpectedErrors: unexpectedErrors
        )
    }

    func record(reservation: FilesystemQuarantineReservation) {
        lock.lock()
        reservations.append(reservation)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard let ledgerError = error as? FilesystemQuarantineLedgerError else {
            unexpectedErrors.append(String(describing: error))
            return
        }
        switch ledgerError {
        case .capacityExhausted:
            capacityFailures += 1
        case .lockTimeout:
            lockTimeouts += 1
        default:
            unexpectedErrors.append(String(describing: ledgerError))
        }
    }
}

private final class AtomicLeafSwapMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let peer: URL
    private var applied = false
    private var storedError: Error?
    private var storedTargetPath: String?

    init(peer: URL) {
        self.peer = peer
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var targetPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedTargetPath
    }

    func apply(to target: URL) {
        lock.lock()
        guard !applied else {
            lock.unlock()
            return
        }
        applied = true
        storedTargetPath = target.path
        lock.unlock()

        let result = target.path.withCString { targetPath in
            peer.path.withCString { peerPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    targetPath,
                    AT_FDCWD,
                    peerPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            let error = NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: target.path]
            )
            lock.lock()
            storedError = error
            lock.unlock()
            return
        }
    }
}

private final class DirectorySwapMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let originalParent: URL
    private let relocatedParent: URL
    private let replacementName: String
    private let replacementData: Data
    private var applied = false
    private var storedError: Error?

    init(
        originalParent: URL,
        relocatedParent: URL,
        replacementName: String,
        replacementData: Data
    ) {
        self.originalParent = originalParent
        self.relocatedParent = relocatedParent
        self.replacementName = replacementName
        self.replacementData = replacementData
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func apply() {
        lock.lock()
        guard !applied else {
            lock.unlock()
            return
        }
        applied = true
        lock.unlock()

        do {
            try FileManager.default.moveItem(at: originalParent, to: relocatedParent)
            try FileManager.default.createDirectory(
                at: originalParent,
                withIntermediateDirectories: false
            )
            try replacementData.write(
                to: originalParent.appendingPathComponent(replacementName)
            )
        } catch {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }
}

private final class ParentBecomesFileMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let relocatedParent: URL
    private var applied = false
    private var storedError: Error?

    init(parent: URL, relocatedParent: URL) {
        self.parent = parent
        self.relocatedParent = relocatedParent
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func apply() {
        lock.lock()
        guard !applied else {
            lock.unlock()
            return
        }
        applied = true
        lock.unlock()

        do {
            try FileManager.default.moveItem(at: parent, to: relocatedParent)
            try Data("not-a-directory".utf8).write(to: parent)
        } catch {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }
}

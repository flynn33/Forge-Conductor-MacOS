import Darwin
import Foundation
import ServiceManagement
import XCTest
import ForgeFilesystemProtocol
@testable import ForgeConductorCore

final class SecureFilesystemMutationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "secure-filesystem-mutation-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testProductionPackRejectsDeleteWithoutDurableContextAndPreservesLeaf() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let leaf = root.appendingPathComponent("preserved-delete.txt")
        try Data("preserve".utf8).write(to: leaf)

        let result = try XCTUnwrap(try FilesystemToolPack().handle(
            name: "fs_delete",
            arguments: ["path": leaf.path],
            context: nil,
            clientID: ClientID("production-delete-no-context"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testProductionPackDisablesMoveWithoutSameUserFallback() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let source = root.appendingPathComponent("preserved-move.txt")
        let destination = root.appendingPathComponent("must-not-exist.txt")
        try Data("preserve".utf8).write(to: source)

        let result = try XCTUnwrap(try FilesystemToolPack().handle(
            name: "fs_move",
            arguments: ["path": source.path, "dest": destination.path],
            context: makeContext(),
            clientID: ClientID("production-move-disabled"),
            app: app,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        ))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPrivilegedClientRejectsDirectoryWithoutXPCOrSameUserFallback() throws {
        let directory = root.appendingPathComponent("preserved-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let child = directory.appendingPathComponent("child.txt")
        try Data("preserve".utf8).write(to: child)
        let transport = SecureFilesystemTransportStub(status: .enabled)

        let result = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: directory,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: makeRecoveryLedger(label: "directory-disabled")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: child), Data("preserve".utf8))
    }

    func testProductionPackKeepsRegularLeafDeleteOnPrivilegedClient() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let project = root.appendingPathComponent("leaf-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let leaf = project.appendingPathComponent("protected-leaf.txt")
        try Data("preserve".utf8).write(to: leaf)
        let clientID = ClientID("production-privileged-leaf")
        _ = try bindProductionProject(app: app, project: project, clientID: clientID)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "identity mismatch"
            )
        )
        let router = ToolRouter(
            app: app,
            packs: [FilesystemToolPack(
                secureMutationClient: SecureFilesystemMutationClient(transport: transport)
            )]
        )

        let result = try router.call(
            name: "fs_delete",
            arguments: ["path": leaf.path],
            clientID: clientID,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperIdentityMismatch
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testProductionPackKeepsSymlinkLeafDeleteOnPrivilegedClient() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let project = root.appendingPathComponent("symlink-leaf-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("symlink-target.txt")
        try Data("outside-preserved".utf8).write(to: outside)
        let link = project.appendingPathComponent("protected-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let clientID = ClientID("production-privileged-symlink")
        _ = try bindProductionProject(app: app, project: project, clientID: clientID)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "identity mismatch"
            )
        )
        let router = ToolRouter(
            app: app,
            packs: [FilesystemToolPack(
                secureMutationClient: SecureFilesystemMutationClient(transport: transport)
            )]
        )

        let result = try router.call(
            name: "fs_delete",
            arguments: ["path": link.path],
            clientID: clientID,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperIdentityMismatch
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-preserved".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            outside.path
        )
    }

    func testProductionLocalMutationsRequireDurableProjectContext() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let directory = root.appendingPathComponent("no-context-directory", isDirectory: true)
        let source = root.appendingPathComponent("no-context-source.txt")
        let destination = root.appendingPathComponent("no-context-destination.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: directory.appendingPathComponent("child.txt"))
        try Data("preserve".utf8).write(to: source)
        let transport = SecureFilesystemTransportStub(status: .enabled)
        let pack = FilesystemToolPack(
            secureMutationClient: SecureFilesystemMutationClient(transport: transport)
        )

        for (name, arguments) in [
            ("fs_delete", ["path": directory.path]),
            ("fs_move", ["path": source.path, "dest": destination.path]),
        ] {
            let result = try XCTUnwrap(try pack.handle(
                name: name,
                arguments: arguments,
                context: nil,
                clientID: ClientID("production-local-no-context"),
                app: app,
                cancellation: ToolCallCancellation(timeoutSeconds: 5)
            ))
            XCTAssertFalse(result.ok)
            XCTAssertEqual(
                result.payload["code"] as? String,
                ForgeFilesystemErrorCode.capabilityUnavailable
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(transport.deleteCallCount, 0)
    }

    func testProductionLocalMutationsRejectProjectRootSymlinkEscape() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let project = root.appendingPathComponent("escape-project", isDirectory: true)
        let outside = root.appendingPathComponent("outside-project", isDirectory: true)
        let outsideDirectory = outside.appendingPathComponent("preserved", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideLeaf = outsideDirectory.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideLeaf)
        let escape = project.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let source = project.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        let clientID = ClientID("production-project-escape")
        _ = try bindProductionProject(app: app, project: project, clientID: clientID)
        let transport = SecureFilesystemTransportStub(status: .enabled)
        let router = ToolRouter(
            app: app,
            packs: [FilesystemToolPack(
                secureMutationClient: SecureFilesystemMutationClient(transport: transport)
            )]
        )

        let delete = try router.call(
            name: "fs_delete",
            arguments: ["path": escape.appendingPathComponent("preserved").path],
            clientID: clientID,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        )
        let move = try router.call(
            name: "fs_move",
            arguments: [
                "path": source.path,
                "dest": escape.appendingPathComponent("moved.txt").path,
            ],
            clientID: clientID,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        )

        for result in [delete, move] {
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
        }
        XCTAssertEqual(try Data(contentsOf: outsideLeaf), Data("outside".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("moved.txt").path
            )
        )
        XCTAssertEqual(transport.deleteCallCount, 0)
    }

    func testProductionDirectoryDeleteFailsClosedWithoutLocalMutation() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app"))
        defer { app.shutdown() }
        let project = root.appendingPathComponent("limit-project", isDirectory: true)
        let directory = project.appendingPathComponent("too-many", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let clientID = ClientID("production-recursive-limit")
        _ = try bindProductionProject(app: app, project: project, clientID: clientID)
        let transport = SecureFilesystemTransportStub(status: .enabled)
        let router = ToolRouter(
            app: app,
            packs: [FilesystemToolPack(
                secureMutationClient: SecureFilesystemMutationClient(transport: transport)
            )]
        )

        let result = try router.call(
            name: "fs_delete",
            arguments: ["path": directory.path],
            clientID: clientID,
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(transport.deleteCallCount, 0)
    }

    func testSecureClientMapsUnavailableStatusesWithoutDispatchingMutation() throws {
        for status in [
            SecureFilesystemServiceStatus.notRegistered,
            SecureFilesystemServiceStatus.notFound,
        ] {
            let leaf = try makeLeaf(named: "unavailable-\(status.rawValue).txt")
            let transport = SecureFilesystemTransportStub(status: status)
            let client = SecureFilesystemMutationClient(transport: transport)

            let result = try client.deleteLeaf(
                at: leaf,
                context: makeContext(),
                cancellation: ToolCallCancellation(timeoutSeconds: 5),
                recoveryLedger: makeRecoveryLedger(label: status.rawValue)
            )

            XCTAssertFalse(result.ok)
            XCTAssertEqual(
                result.payload["code"] as? String,
                ForgeFilesystemErrorCode.helperUnavailable
            )
            XCTAssertEqual(transport.deleteCallCount, 0)
            XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
        }
    }

    func testSecureClientMapsApprovalRequirementWithoutDispatchingMutation() throws {
        let leaf = try makeLeaf(named: "approval-required.txt")
        let transport = SecureFilesystemTransportStub(status: .requiresApproval)
        let client = SecureFilesystemMutationClient(transport: transport)

        let result = try client.deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: makeRecoveryLedger(label: "approval")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperNotApproved
        )
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testSecureClientPreservesLeafWhenHelperIdentityDoesNotMatch() throws {
        let leaf = try makeLeaf(named: "identity-mismatch.txt")
        let response = ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperIdentityMismatch,
            message: "identity mismatch"
        )
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            response: response
        )
        let client = SecureFilesystemMutationClient(transport: transport)

        let result = try client.deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: makeRecoveryLedger(label: "identity")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperIdentityMismatch,
            "\(result.payload)"
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testProductionDeleteDispatchUsesCurrentEntryContractAndCanonicalDigest() throws {
        let leaf = try makeLeaf(named: "current-entry-contract.txt")
        let ledger = makeRecoveryLedger(label: "current-entry-contract")
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                XCTAssertEqual(request.contract, .currentEntry)
                XCTAssertNil(request.expectedLeafIdentity)
                XCTAssertNil(request.validationError())
                XCTAssertNotNil(
                    request.requestDigestSHA256.range(
                        of: #"^[0-9a-f]{64}$"#,
                        options: .regularExpression
                    ),
                    request.requestDigestSHA256
                )
                return ForgeFilesystemResponse(
                    ok: false,
                    code: ForgeFilesystemErrorCode.helperUnavailable,
                    message: "unavailable"
                )
            }
        )

        _ = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try ledger.retainedCount(), 0)
    }

    func testDurableQuarantineFailurePreservesTypedFailureAndRecoveryAuthority() throws {
        let leaf = try makeLeaf(named: "durable-quarantine-failure.txt")
        let ledger = makeRecoveryLedger(label: "durable-quarantine-failure")
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: false,
                    code: ForgeFilesystemErrorCode.versionConflict,
                    message: "Captured entry retained in protected quarantine",
                    committed: false,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: false
                )
            }
        )

        let result = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.versionConflict,
            "\(result.payload)"
        )
        XCTAssertNotEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.protocolMismatch
        )
        XCTAssertEqual(result.payload["recovery_required"] as? Bool, true)
        XCTAssertEqual(result.payload["acknowledgement_required"] as? Bool, false)
        XCTAssertEqual(result.payload["committed"] as? Bool, false)
        XCTAssertEqual(result.payload["durability_confirmed"] as? Bool, true)
        let transactionID = try XCTUnwrap(
            result.payload["filesystem_transaction_id"] as? String
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
        XCTAssertEqual(try ledger.retainedCount(), 1)
    }

    func testSubmittedRequestWithoutReplyRetainsOriginalRecoveryTransactionID() throws {
        let request = makeMutationRequest()

        let response = XPCSecureFilesystemServiceTransport.uncertainFailure(
            for: request,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service request timed out"
        )

        XCTAssertFalse(response.ok)
        XCTAssertFalse(response.committed)
        XCTAssertFalse(response.durabilityConfirmed)
        XCTAssertEqual(response.recoveryTransactionID, request.transactionID)
    }

    func testCallerRecoveryLedgerRetainsExactAuthorityUntilAcknowledgement() throws {
        let ledger = SecureFilesystemRecoveryLedger(
            root: root.appendingPathComponent("caller-recovery-ledger", isDirectory: true)
        )
        let request = makeMutationRequest()
        let record = SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("recovery-origin"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        )

        try ledger.retain(record)
        try ledger.retain(record)

        XCTAssertEqual(try ledger.retainedCount(), 1)
        XCTAssertEqual(try ledger.record(transactionID: request.transactionID), record)
        XCTAssertTrue(try ledger.remove(transactionID: request.transactionID))
        XCTAssertFalse(try ledger.remove(transactionID: request.transactionID))
        XCTAssertNil(try ledger.record(transactionID: request.transactionID))
    }

    func testSameUIDLedgerDirectoryRenameCausesBoundedRecoveryLossWithoutXPCDispatch() throws {
        let context = makeContext()
        let leaf = try makeLeaf(named: "same-uid-ledger-rename.txt")
        let ledgerRoot = root.appendingPathComponent(
            "caller-recovery-same-uid-rename",
            isDirectory: true
        )
        let ledger = SecureFilesystemRecoveryLedger(root: ledgerRoot)
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let deleted = try SecureFilesystemMutationClient(
            transport: deleteTransport
        ).deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))

        let displacedRoot = root.appendingPathComponent(
            "caller-recovery-same-uid-displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: ledgerRoot, to: displacedRoot)
        let recoveryTransport = SecureFilesystemTransportStub(status: .enabled)
        let result = try SecureFilesystemMutationClient(
            transport: recoveryTransport
        ).recoverDelete(
            transactionID: transactionID,
            action: "query",
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.transactionUnavailable
        )
        XCTAssertEqual(recoveryTransport.queryCallCount, 0)
        XCTAssertNotNil(try SecureFilesystemRecoveryLedger(
            root: displacedRoot
        ).record(transactionID: transactionID))
    }

    func testCallerRecoveryLedgerTreatsOriginatingClientAsAuditOnly() throws {
        let ledger = makeRecoveryLedger(label: "client-restart")
        let request = makeMutationRequest()
        let original = SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("original-client"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        )
        let restarted = SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("restarted-client"),
            rootPath: root.path,
            createdAtMilliseconds: 2
        )

        try ledger.retain(original)
        try ledger.retain(restarted)

        XCTAssertEqual(try ledger.retainedCount(), 1)
        XCTAssertEqual(
            try ledger.record(transactionID: request.transactionID)?.originatingClientID,
            "original-client"
        )
    }

    func testCallerRecoveryLedgerFailsClosedAtFixedCapacity() throws {
        let ledger = SecureFilesystemRecoveryLedger(
            root: root.appendingPathComponent("full-caller-recovery-ledger", isDirectory: true)
        )
        for index in 0..<SecureFilesystemRecoveryLedger.maximumRecords {
            let record = SecureFilesystemRecoveryRecord(
                request: makeMutationRequest(),
                originatingClientID: ClientID("recovery-origin-\(index)"),
                rootPath: root.path,
                createdAtMilliseconds: Int64(index + 1)
            )
            try ledger.retain(record)
        }

        XCTAssertEqual(
            try ledger.retainedCount(),
            SecureFilesystemRecoveryLedger.maximumRecords
        )
        XCTAssertThrowsError(try ledger.retain(SecureFilesystemRecoveryRecord(
            request: makeMutationRequest(),
            originatingClientID: ClientID("recovery-overflow"),
            rootPath: root.path,
            createdAtMilliseconds: 100
        ))) { error in
            XCTAssertEqual(
                error as? SecureFilesystemRecoveryLedgerError,
                .capacityExhausted
            )
        }
    }

    func testRegisteredButNonOperationalServiceDoesNotRetainOrDispatchMutation() throws {
        let leaf = try makeLeaf(named: "registered-runtime-unavailable.txt")
        let ledger = makeRecoveryLedger(label: "registered-runtime-unavailable")
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            operationalProbe: SecureFilesystemServiceOperationalProbe(
                operational: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "registered service did not answer"
            )
        )

        let result = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperUnavailable
        )
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertEqual(transport.queryCallCount, 0)
        XCTAssertEqual(try ledger.retainedCount(), 0)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testRestartReconciliationPurgesVerifiedTerminalTransaction() throws {
        let ledgerRoot = root.appendingPathComponent(
            "terminal-restart-recovery",
            isDirectory: true
        )
        let initialLedger = SecureFilesystemRecoveryLedger(root: ledgerRoot)
        let request = try makeMutationRequest(rootedAt: root)
        let record = SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("before-restart"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        )
        try initialLedger.retain(record)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            transactionStatusProvider: { request in
                ForgeFilesystemTransactionStatus(
                    transactionID: request.transactionID,
                    disposition: .committed,
                    code: "ok",
                    message: "committed",
                    terminal: true,
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryRequired: false,
                    acknowledgementRequired: true
                )
            },
            acknowledgeResponseProvider: { _ in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "acknowledged",
                    durabilityConfirmed: true
                )
            }
        )

        let restartedLedger = SecureFilesystemRecoveryLedger(root: ledgerRoot)
        let reconciliation = SecureFilesystemMutationClient(
            transport: transport
        ).reconcileRecoveryLedger(
            recoveryLedger: restartedLedger,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            purgeTerminalReceipts: true
        )

        XCTAssertTrue(reconciliation.available)
        XCTAssertEqual(reconciliation.releasedCount, 1)
        XCTAssertEqual(reconciliation.retainedCount, 0)
        XCTAssertEqual(transport.queryCallCount, 1)
        XCTAssertEqual(transport.acknowledgeCallCount, 1)
        XCTAssertNil(try restartedLedger.record(transactionID: request.transactionID))
    }

    func testRestartReconciliationKeepsQuarantinedTransactionUnresolved() throws {
        let ledger = makeRecoveryLedger(label: "quarantined-restart")
        let request = try makeMutationRequest(rootedAt: root)
        try ledger.retain(SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("before-restart"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        ))
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            transactionStatusProvider: { request in
                ForgeFilesystemTransactionStatus(
                    transactionID: request.transactionID,
                    disposition: .quarantined,
                    code: ForgeFilesystemErrorCode.versionConflict,
                    message: "protected leaf retained",
                    terminal: true,
                    committed: false,
                    durabilityConfirmed: true,
                    recoveryRequired: true,
                    acknowledgementRequired: false
                )
            }
        )

        let reconciliation = SecureFilesystemMutationClient(
            transport: transport
        ).reconcileRecoveryLedger(
            recoveryLedger: ledger,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            purgeTerminalReceipts: true
        )

        XCTAssertTrue(reconciliation.available)
        XCTAssertEqual(reconciliation.releasedCount, 0)
        XCTAssertEqual(reconciliation.retainedCount, 1)
        XCTAssertEqual(transport.queryCallCount, 1)
        XCTAssertEqual(transport.acknowledgeCallCount, 0)
        XCTAssertEqual(transport.resumeCallCount, 0)
        XCTAssertNotNil(try ledger.record(transactionID: request.transactionID))
    }

    func testPreMutationReconciliationReportsExhaustedUnresolvedDebt() throws {
        let ledger = makeRecoveryLedger(label: "unresolved-capacity")
        for index in 0..<SecureFilesystemRecoveryLedger.maximumRecords {
            let request = try makeMutationRequest(rootedAt: root)
            try ledger.retain(SecureFilesystemRecoveryRecord(
                request: request,
                originatingClientID: ClientID("capacity-\(index)"),
                rootPath: root.path,
                createdAtMilliseconds: Int64(index + 1)
            ))
        }
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            transactionStatusProvider: { request in
                ForgeFilesystemTransactionStatus(
                    transactionID: request.transactionID,
                    disposition: .recoveryRequired,
                    code: ForgeFilesystemErrorCode.transactionNotTerminal,
                    message: "requires explicit recovery",
                    terminal: false,
                    committed: false,
                    durabilityConfirmed: false,
                    recoveryRequired: true,
                    acknowledgementRequired: false
                )
            }
        )
        let leaf = try makeLeaf(named: "blocked-by-recovery-capacity.txt")

        let result = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.protectedNamespaceUnavailable
        )
        XCTAssertEqual(
            result.payload["recovery_debt_count"] as? Int,
            SecureFilesystemRecoveryLedger.maximumRecords
        )
        XCTAssertEqual(
            result.payload["recovery_debt_capacity"] as? Int,
            SecureFilesystemRecoveryLedger.maximumRecords
        )
        XCTAssertEqual(transport.queryCallCount, SecureFilesystemRecoveryLedger.maximumRecords)
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testCallerRecoveryLedgerRejectsConflictingTransactionAuthority() throws {
        let ledger = SecureFilesystemRecoveryLedger(
            root: root.appendingPathComponent("conflicting-caller-recovery-ledger", isDirectory: true)
        )
        let transactionID = UUID().uuidString.lowercased()
        let first = SecureFilesystemRecoveryRecord(
            request: makeMutationRequest(transactionID: transactionID),
            originatingClientID: ClientID("recovery-origin"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        )
        let conflicting = SecureFilesystemRecoveryRecord(
            request: makeMutationRequest(transactionID: transactionID),
            originatingClientID: ClientID("recovery-origin"),
            rootPath: root.appendingPathComponent("other").path,
            createdAtMilliseconds: 2
        )
        try ledger.retain(first)

        XCTAssertThrowsError(try ledger.retain(conflicting)) { error in
            XCTAssertEqual(
                error as? SecureFilesystemRecoveryLedgerError,
                .conflictingTransaction
            )
        }
        XCTAssertEqual(try ledger.record(transactionID: transactionID), first)
    }

    func testCallerRecoveryLedgerTreatsMalformedOccupiedSlotAsUnavailable() throws {
        let ledgerRoot = root.appendingPathComponent(
            "malformed-caller-recovery-ledger",
            isDirectory: true
        )
        let ledger = SecureFilesystemRecoveryLedger(root: ledgerRoot)
        _ = try ledger.retainedCount()
        try Data("not-json".utf8).write(
            to: ledgerRoot.appendingPathComponent("slot-00.json")
        )

        XCTAssertThrowsError(try ledger.retainedCount()) { error in
            XCTAssertEqual(
                error as? SecureFilesystemRecoveryLedgerError,
                .unavailable
            )
        }
    }

    func testDeletePersistsCallerAuthorityBeforeDispatchAndPathlessRecoverySurvivesRestart() throws {
        let leaf = try makeLeaf(named: "pathless-recovery.txt")
        let context = makeContext()
        let ledger = makeRecoveryLedger(label: "pathless-restart")
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let originalClient = SecureFilesystemMutationClient(transport: deleteTransport)

        let deleted = try originalClient.deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertTrue(deleted.ok, "\(deleted.payload)")
        XCTAssertEqual(deleteTransport.deleteCallCount, 1)
        XCTAssertEqual(deleted.payload["acknowledgement_required"] as? Bool, true)
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
        try FileManager.default.removeItem(at: leaf)

        let recoveryTransport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: true,
                code: "ok",
                message: "acknowledged",
                durabilityConfirmed: true
            ),
            transactionStatus: ForgeFilesystemTransactionStatus(
                transactionID: transactionID,
                disposition: .committed,
                code: "ok",
                message: "deleted",
                terminal: true,
                committed: true,
                durabilityConfirmed: true,
                recoveryRequired: false,
                acknowledgementRequired: true
            )
        )
        let restartedClient = SecureFilesystemMutationClient(transport: recoveryTransport)
        let queried = try restartedClient.recoverDelete(
            transactionID: transactionID,
            action: "query",
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertTrue(queried.ok, "\(queried.payload)")
        XCTAssertEqual(queried.payload["disposition"] as? String, "committed")
        XCTAssertEqual(recoveryTransport.queryCallCount, 1)

        let acknowledged = try restartedClient.recoverDelete(
            transactionID: transactionID,
            action: "acknowledge",
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertTrue(acknowledged.ok, "\(acknowledged.payload)")
        XCTAssertEqual(recoveryTransport.acknowledgeCallCount, 1)
        XCTAssertNil(try ledger.record(transactionID: transactionID))
    }

    func testQuarantinedQuerySurfacesTerminalRecoveryStateAndRetainsAuthority() throws {
        let leaf = try makeLeaf(named: "quarantined-query.txt")
        let context = makeContext()
        let ledger = makeRecoveryLedger(label: "quarantined-query")
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let deleted = try SecureFilesystemMutationClient(
            transport: deleteTransport
        ).deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        let recoveryTransport = SecureFilesystemTransportStub(
            status: .enabled,
            transactionStatus: ForgeFilesystemTransactionStatus(
                transactionID: transactionID,
                disposition: .quarantined,
                code: ForgeFilesystemErrorCode.versionConflict,
                message: "Captured entry retained in protected quarantine",
                terminal: true,
                committed: false,
                durabilityConfirmed: true,
                recoveryRequired: true,
                acknowledgementRequired: false
            )
        )

        let queried = try SecureFilesystemMutationClient(
            transport: recoveryTransport
        ).recoverDelete(
            transactionID: transactionID,
            action: "query",
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertTrue(queried.ok, "\(queried.payload)")
        XCTAssertEqual(queried.payload["transaction_id"] as? String, transactionID)
        XCTAssertEqual(queried.payload["disposition"] as? String, "quarantined")
        XCTAssertEqual(
            queried.payload["code"] as? String,
            ForgeFilesystemErrorCode.versionConflict
        )
        XCTAssertEqual(queried.payload["terminal"] as? Bool, true)
        XCTAssertEqual(queried.payload["committed"] as? Bool, false)
        XCTAssertEqual(queried.payload["durability_confirmed"] as? Bool, true)
        XCTAssertEqual(queried.payload["recovery_required"] as? Bool, true)
        XCTAssertEqual(queried.payload["acknowledgement_required"] as? Bool, false)
        XCTAssertEqual(recoveryTransport.queryCallCount, 1)
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
        XCTAssertEqual(try ledger.retainedCount(), 1)
    }

    func testFullCallerRecoveryLedgerPreventsDeleteDispatch() throws {
        let leaf = try makeLeaf(named: "full-ledger-preserved.txt")
        let context = makeContext()
        let ledger = makeRecoveryLedger(label: "predispatch-full")
        for index in 0..<SecureFilesystemRecoveryLedger.maximumRecords {
            try ledger.retain(SecureFilesystemRecoveryRecord(
                request: makeMutationRequest(),
                originatingClientID: ClientID("retained-\(index)"),
                rootPath: root.path,
                createdAtMilliseconds: Int64(index + 1)
            ))
        }
        let transport = SecureFilesystemTransportStub(status: .enabled)
        let client = SecureFilesystemMutationClient(transport: transport)

        let result = try client.deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.protectedNamespaceUnavailable
        )
        XCTAssertEqual(
            result.payload["recovery_debt_count"] as? Int,
            SecureFilesystemRecoveryLedger.maximumRecords
        )
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    func testDeleteWaitingBehindGenerationResetCannotRetainOrDispatchStaleAuthority() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("app", isDirectory: true))
        defer { app.shutdown() }
        let project = root.appendingPathComponent("reset-fenced-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let leaf = project.appendingPathComponent("preserved-after-reset.txt")
        try Data("preserve".utf8).write(to: leaf)
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)

        let resetReached = DispatchSemaphore(value: 0)
        let allowReset = DispatchSemaphore(value: 0)
        let resetCompleted = DispatchSemaphore(value: 0)
        let resetSucceeded = SynchronizedBoolean()
        let manager = ManagerNode(app: app) { _, _ in
            resetReached.signal()
            guard allowReset.wait(timeout: .now() + 5) == .success else {
                throw GenerationResetFixtureError.timeout
            }
        }
        let registered = try manager.registerProject(
            path: project.path,
            displayName: "Reset Fenced Project"
        )
        let projectID = ProjectID(try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
        ))
        let clientID = ClientID("stale-delete-after-reset")
        _ = try manager.bindProject(
            projectID: projectID,
            expectedGeneration: .initial,
            owner: ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        )
        let context = try app.projectContexts.invocationContext(for: clientID)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try manager.resetProjectGeneration(
                    projectID: projectID,
                    expectedGeneration: .initial
                )
                resetSucceeded.set(true)
            } catch {
                resetSucceeded.set(false)
            }
            resetCompleted.signal()
        }
        XCTAssertEqual(resetReached.wait(timeout: .now() + 5), .success)

        let transport = SecureFilesystemTransportStub(status: .enabled)
        let recoveryLedger = SecureFilesystemRecoveryLedger(paths: app.paths)
        let result = try SecureFilesystemMutationClient(transport: transport).deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: recoveryLedger,
            authorityValidator: { currentContext in
                try app.projectContexts.validate(currentContext)
            },
            retentionAttemptObserver: {
                allowReset.signal()
            }
        )

        XCTAssertEqual(resetCompleted.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(resetSucceeded.value)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.payload["code"] as? String, "stale_project_generation")
        XCTAssertEqual(transport.deleteCallCount, 0)
        XCTAssertEqual(try recoveryLedger.retainedCount(), 0)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
        XCTAssertEqual(
            try manager.projectStatus(projectID: projectID)["project_generation"] as? UInt64,
            2
        )
    }

    func testRecoveryRejectsDifferentProjectBeforeXPC() throws {
        let leaf = try makeLeaf(named: "project-fenced-recovery.txt")
        let originalContext = makeContext()
        let ledger = makeRecoveryLedger(label: "project-fence")
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let client = SecureFilesystemMutationClient(transport: deleteTransport)
        let deleted = try client.deleteLeaf(
            at: leaf,
            context: originalContext,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        let recoveryTransport = SecureFilesystemTransportStub(status: .enabled)
        let restartedClient = SecureFilesystemMutationClient(transport: recoveryTransport)

        let result = try restartedClient.recoverDelete(
            transactionID: transactionID,
            action: "query",
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertEqual(recoveryTransport.queryCallCount, 0)
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
    }

    func testRecoveryRejectsDifferentWritableRootBeforeXPC() throws {
        let leaf = try makeLeaf(named: "root-fenced-recovery.txt")
        let originalContext = makeContext()
        let ledger = makeRecoveryLedger(label: "root-fence")
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let deleted = try SecureFilesystemMutationClient(
            transport: deleteTransport
        ).deleteLeaf(
            at: leaf,
            context: originalContext,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        let otherRoot = root.appendingPathComponent("other-root", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let mismatchedContext = ToolInvocationContext(
            projectID: originalContext.projectID,
            projectGeneration: originalContext.projectGeneration,
            clientID: originalContext.clientID,
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [otherRoot],
                writableRoots: [otherRoot],
                allowedTools: ["fs_delete"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let recoveryTransport = SecureFilesystemTransportStub(status: .enabled)

        let result = try SecureFilesystemMutationClient(
            transport: recoveryTransport
        ).recoverDelete(
            transactionID: transactionID,
            action: "query",
            context: mismatchedContext,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.capabilityUnavailable
        )
        XCTAssertEqual(recoveryTransport.queryCallCount, 0)
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
    }

    func testMismatchedDeleteResponseCannotReleaseCallerRecoveryAuthority() throws {
        let leaf = try makeLeaf(named: "mismatched-response-preserved.txt")
        let ledger = makeRecoveryLedger(label: "mismatched-response")
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { _ in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: UUID().uuidString.lowercased(),
                    acknowledgementRequired: true
                )
            }
        )

        let result = try SecureFilesystemMutationClient(
            transport: transport
        ).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.protocolMismatch
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try ledger.retainedCount(), 1)
    }

    func testUndurableDeleteSuccessCannotReleaseCallerRecoveryAuthority() throws {
        let leaf = try makeLeaf(named: "undurable-response-preserved.txt")
        let ledger = makeRecoveryLedger(label: "undurable-response")
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: true,
                code: "ok",
                message: "deleted"
            )
        )

        let result = try SecureFilesystemMutationClient(
            transport: transport
        ).deleteLeaf(
            at: leaf,
            context: makeContext(),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.protocolMismatch
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try ledger.retainedCount(), 1)
    }

    func testDeleteGrantAlsoAuthorizesAdditiveRecoveryTool() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("authorization-app"))
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
        let context = makeContext(allowedTools: ["fs_delete"])
        let binding = ActiveBinding(
            sessionID: SessionID(),
            agentID: "recovery-authorized",
            toolsPrimary: ["fs_delete"]
        )

        let decision = authorization.authorize(
            tool: "fs_delete_recovery",
            arguments: [
                "transaction_id": UUID().uuidString.lowercased(),
                "action": "query",
            ],
            context: context,
            clientID: context.clientID,
            binding: binding
        )

        guard case .allowed = decision else {
            return XCTFail("fs_delete authority must include its additive recovery control")
        }
    }

    func testRecoveryToolRequiresDeleteOrExplicitRecoveryGrant() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("denied-authorization-app"))
        defer { app.shutdown() }
        let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
        let context = makeContext(allowedTools: ["fs_read"])

        let decision = authorization.authorize(
            tool: "fs_delete_recovery",
            arguments: [
                "transaction_id": UUID().uuidString.lowercased(),
                "action": "query",
            ],
            context: context,
            clientID: context.clientID,
            binding: nil
        )

        guard case let .denied(code, _) = decision else {
            return XCTFail("recovery without delete authority must be denied")
        }
        XCTAssertEqual(code, "tool_not_granted")
    }

    func testDeleteForbidRuleAlsoForbidsAdditiveRecoveryTool() throws {
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("forbidden-authorization-app"))
        defer { app.shutdown() }
        let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
        let context = makeContext(allowedTools: ["fs_delete_recovery"])
        let binding = ActiveBinding(
            sessionID: SessionID(),
            agentID: "recovery-forbidden",
            toolsPrimary: ["fs_delete_recovery"],
            toolsForbidden: ["fs_delete"]
        )

        let decision = authorization.authorize(
            tool: "fs_delete_recovery",
            arguments: [
                "transaction_id": UUID().uuidString.lowercased(),
                "action": "query",
            ],
            context: context,
            clientID: context.clientID,
            binding: binding
        )

        guard case let .denied(code, _) = decision else {
            return XCTFail("fs_delete forbid rule must cover its recovery control")
        }
        XCTAssertEqual(code, "tool_forbidden")
    }

    func testFailedDaemonAcknowledgementRetainsCallerRecoveryAuthority() throws {
        let leaf = try makeLeaf(named: "ack-failure-retained.txt")
        let context = makeContext()
        let ledger = makeRecoveryLedger(label: "ack-failure")
        let deleteTransport = SecureFilesystemTransportStub(
            status: .enabled,
            deleteResponseProvider: { request in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "deleted",
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryTransactionID: request.transactionID,
                    acknowledgementRequired: true
                )
            }
        )
        let deleted = try SecureFilesystemMutationClient(
            transport: deleteTransport
        ).deleteLeaf(
            at: leaf,
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )
        let transactionID = try XCTUnwrap(
            deleted.payload["filesystem_transaction_id"] as? String
        )
        let recoveryTransport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "reply lost",
                recoveryTransactionID: transactionID
            )
        )

        let result = try SecureFilesystemMutationClient(
            transport: recoveryTransport
        ).recoverDelete(
            transactionID: transactionID,
            action: "acknowledge",
            context: context,
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: ledger
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(recoveryTransport.acknowledgeCallCount, 1)
        XCTAssertNotNil(try ledger.record(transactionID: transactionID))
    }

    func testHandshakeIdentityMismatchCannotDispatchAndReturnsNoRecoveryID() {
        let request = makeMutationRequest()
        var machine = SecureFilesystemHandshakeStateMachine(request: request)
        let disposition = machine.receiveServiceInfo(
            makeServiceInfo(codeDirectoryHash: String(repeating: "b", count: 40)),
            allowedCodeDirectoryHashes: [String(repeating: "a", count: 40)]
        )

        XCTAssertEqual(disposition, .finishWithoutDispatch)
        var dispatchCount = 0
        XCTAssertFalse(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(
            machine.terminalResponse?.code,
            ForgeFilesystemErrorCode.helperIdentityMismatch
        )
        XCTAssertNil(machine.terminalResponse?.recoveryTransactionID)
    }

    func testHandshakeTimeoutCannotDispatchAndReturnsNoRecoveryID() {
        let request = makeMutationRequest()
        var machine = SecureFilesystemHandshakeStateMachine(request: request)

        XCTAssertTrue(machine.completeWithoutReply(
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service request timed out"
        ))

        var dispatchCount = 0
        XCTAssertFalse(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertNil(machine.terminalResponse?.recoveryTransactionID)
    }

    func testLateHandshakeAfterTimeoutCannotDispatch() {
        let request = makeMutationRequest()
        let allowedHash = String(repeating: "a", count: 40)
        var machine = SecureFilesystemHandshakeStateMachine(request: request)
        XCTAssertTrue(machine.completeWithoutReply(
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service request timed out"
        ))

        let disposition = machine.receiveServiceInfo(
            makeServiceInfo(codeDirectoryHash: allowedHash),
            allowedCodeDirectoryHashes: [allowedHash]
        )

        XCTAssertEqual(disposition, .ignore)
        var dispatchCount = 0
        XCTAssertFalse(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(machine.terminalResponse?.recoveryTransactionID)
    }

    func testTimeoutAfterIdentityBeforeSubmissionCannotDispatchAndReturnsNoRecoveryID() {
        let request = makeMutationRequest()
        let allowedHash = String(repeating: "a", count: 40)
        var machine = SecureFilesystemHandshakeStateMachine(request: request)
        XCTAssertEqual(
            machine.receiveServiceInfo(
                makeServiceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .prepareDispatch
        )

        XCTAssertTrue(machine.completeWithoutReply(
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service request timed out"
        ))

        var dispatchCount = 0
        XCTAssertFalse(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(machine.phase, .finished)
        XCTAssertNil(machine.terminalResponse?.recoveryTransactionID)
    }

    func testExactHandshakeMayDispatchOnlyOnceOnConnection() {
        let request = makeMutationRequest()
        let allowedHash = String(repeating: "a", count: 40)
        let serviceInfo = makeServiceInfo(codeDirectoryHash: allowedHash)
        var machine = SecureFilesystemHandshakeStateMachine(request: request)

        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo,
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .prepareDispatch
        )
        var dispatchCount = 0
        XCTAssertTrue(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertFalse(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo,
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .ignore
        )
        XCTAssertEqual(machine.phase, .requestSubmitted)
    }

    func testSubmittedHandshakeLosingReplyPreservesOriginalTransactionID() {
        let request = makeMutationRequest()
        let allowedHash = String(repeating: "a", count: 40)
        var machine = SecureFilesystemHandshakeStateMachine(request: request)
        XCTAssertEqual(
            machine.receiveServiceInfo(
                makeServiceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .prepareDispatch
        )
        var dispatchCount = 0
        XCTAssertTrue(machine.dispatchIfAuthorized { dispatchCount += 1 })
        XCTAssertEqual(dispatchCount, 1)

        XCTAssertTrue(machine.completeWithoutReply(
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service request timed out"
        ))

        XCTAssertEqual(machine.phase, .finished)
        XCTAssertEqual(
            machine.terminalResponse?.recoveryTransactionID,
            request.transactionID
        )
    }

    func testCLINotFoundStatusProbesOnlyWithValidSealedDaemonHashes() {
        let hashKey = ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashInfoPlistKeys[0]
        let validInfo: [String: Any] = [
            hashKey: String(repeating: "a", count: 40),
        ]

        XCTAssertEqual(
            XPCSecureFilesystemServiceTransport.transportStatus(
                reportedStatus: .notFound,
                securedInfoDictionary: validInfo
            ),
            .enabled
        )
        XCTAssertEqual(
            XPCSecureFilesystemServiceTransport.transportStatus(
                reportedStatus: .notFound,
                securedInfoDictionary: nil
            ),
            .notFound
        )
        XCTAssertEqual(
            XPCSecureFilesystemServiceTransport.transportStatus(
                reportedStatus: .notFound,
                securedInfoDictionary: [:]
            ),
            .notFound
        )
        XCTAssertEqual(
            XPCSecureFilesystemServiceTransport.transportStatus(
                reportedStatus: .notFound,
                securedInfoDictionary: [hashKey: "malformed"]
            ),
            .notFound
        )
        XCTAssertEqual(
            XPCSecureFilesystemServiceTransport.transportStatus(
                reportedStatus: .notRegistered,
                securedInfoDictionary: validInfo
            ),
            .notRegistered
        )
    }

    func testPresentedStatusMapsOnlyPresentNotFoundToNotRegistered() {
        let rawStatuses: [SecureFilesystemServiceStatus] = [
            .notRegistered,
            .enabled,
            .requiresApproval,
            .notFound,
        ]
        let observations: [SecureFilesystemServicePackageObservation] = [
            .present,
            .missing,
            .invalid,
        ]
        for rawStatus in rawStatuses {
            for observation in observations {
                let expected: SecureFilesystemServiceStatus =
                    rawStatus == .notFound && observation == .present
                        ? .notRegistered
                        : rawStatus
                XCTAssertEqual(
                    SecureFilesystemServiceController.presentedStatus(
                        reportedStatus: rawStatus,
                        packageObservation: observation
                    ),
                    expected,
                    "raw=\(rawStatus.rawValue) package=\(observation)"
                )
            }
        }
    }

    func testSettingsOperationStateAllowsExactlyOneGenerationFencedOperation() throws {
        var state = SecureFilesystemSettingsOperationState()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.activeOperation)

        let enableGeneration = try XCTUnwrap(state.begin(.enable))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.activeOperation, .enable)
        XCTAssertTrue(state.owns(.enable, generation: enableGeneration))

        for conflictingOperation in SecureFilesystemSettingsOperation.allCases {
            XCTAssertNil(
                state.begin(conflictingOperation),
                "\(conflictingOperation.rawValue) must not overlap enable"
            )
        }
        XCTAssertFalse(state.finish(.refresh, generation: enableGeneration))
        XCTAssertFalse(state.finish(.enable, generation: enableGeneration &+ 1))
        XCTAssertTrue(state.isActive)

        state.cancel()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(
            state.finish(.enable, generation: enableGeneration),
            "a cancelled predecessor must not finish a successor generation"
        )

        let successorGeneration = try XCTUnwrap(state.begin(.enable))
        XCTAssertNotEqual(successorGeneration, enableGeneration)
        XCTAssertFalse(state.finish(.enable, generation: enableGeneration))
        XCTAssertTrue(state.finish(.enable, generation: successorGeneration))
        XCTAssertFalse(state.isActive)

        var exhausted = SecureFilesystemSettingsOperationState(generation: UInt64.max)
        XCTAssertNil(exhausted.begin(.refresh), "generation exhaustion must fail closed")
    }

    func testSettingsControlAvailabilityDisablesEveryConflictDuringEveryOperation() throws {
        let statuses: [SecureFilesystemServiceStatus] = [
            .notRegistered,
            .enabled,
            .requiresApproval,
            .notFound,
        ]

        for status in statuses {
            for operation in SecureFilesystemSettingsOperation.allCases {
                var state = SecureFilesystemSettingsOperationState()
                _ = try XCTUnwrap(state.begin(operation))
                let controls = SecureFilesystemSettingsControlAvailability(
                    registrationStatus: status,
                    operationState: state
                )
                XCTAssertFalse(controls.enable, "enable overlapped \(operation.rawValue)")
                XCTAssertFalse(controls.update, "update overlapped \(operation.rawValue)")
                XCTAssertFalse(controls.disable, "disable overlapped \(operation.rawValue)")
                XCTAssertFalse(controls.approval, "approval overlapped \(operation.rawValue)")
                XCTAssertFalse(controls.refresh, "refresh overlapped \(operation.rawValue)")
                XCTAssertFalse(controls.reconcile, "reconcile overlapped \(operation.rawValue)")
                XCTAssertFalse(
                    controls.lifecycleRecovery,
                    "lifecycle recovery overlapped \(operation.rawValue)"
                )
                XCTAssertFalse(operation.accessibilityLabel.isEmpty)
            }
        }
    }

    func testSettingsControlAvailabilityPreservesIdleLifecycleSemantics() {
        let idle = SecureFilesystemSettingsOperationState()
        let notPackaged = SecureFilesystemSettingsControlAvailability(
            registrationStatus: .notFound,
            operationState: idle
        )
        XCTAssertTrue(notPackaged.enable)
        XCTAssertFalse(notPackaged.update)
        XCTAssertFalse(notPackaged.disable)
        XCTAssertTrue(notPackaged.approval)
        XCTAssertTrue(notPackaged.refresh)
        XCTAssertTrue(notPackaged.reconcile)
        XCTAssertFalse(notPackaged.lifecycleRecovery)

        let notRegistered = SecureFilesystemSettingsControlAvailability(
            registrationStatus: .notRegistered,
            operationState: idle
        )
        XCTAssertTrue(notRegistered.enable)
        XCTAssertTrue(notRegistered.update)
        XCTAssertFalse(notRegistered.disable)

        let enabled = SecureFilesystemSettingsControlAvailability(
            registrationStatus: .enabled,
            operationState: idle
        )
        XCTAssertFalse(enabled.enable)
        XCTAssertTrue(enabled.update)
        XCTAssertTrue(enabled.disable)

        let approvalRequired = SecureFilesystemSettingsControlAvailability(
            registrationStatus: .requiresApproval,
            operationState: idle
        )
        XCTAssertTrue(approvalRequired.enable)
        XCTAssertTrue(approvalRequired.update)
        XCTAssertTrue(approvalRequired.disable)
    }

    func testSettingsControlAvailabilityKeepsLifecycleMutationsFencedWhenOutcomeIsUncertain() {
        let idle = SecureFilesystemSettingsOperationState()
        for phase in [
            SecureFilesystemServiceLifecyclePhase.registering,
            SecureFilesystemServiceLifecyclePhase.unregistering,
            .registrationPending,
            .outcomeUncertain,
        ] {
            let controls = SecureFilesystemSettingsControlAvailability(
                registrationStatus: .enabled,
                operationState: idle,
                lifecycleState: SecureFilesystemServiceLifecycleState(
                    phase: phase,
                    intent: .update,
                    operationID: UUID().uuidString.lowercased()
                )
            )
            XCTAssertFalse(controls.enable)
            XCTAssertFalse(controls.update)
            XCTAssertFalse(controls.disable)
            XCTAssertFalse(controls.approval)
            XCTAssertTrue(controls.refresh, "read-only Refresh must remain available")
            XCTAssertFalse(controls.reconcile)
            XCTAssertTrue(controls.lifecycleRecovery)
        }

        XCTAssertEqual(
            SecureFilesystemServiceLifecycleState(
                phase: .registering,
                intent: .enable,
                operationID: UUID().uuidString.lowercased()
            ).operatorStatusLabel,
            "Waiting for macOS to finish registering the service"
        )
        XCTAssertEqual(
            SecureFilesystemServiceLifecycleState(
                phase: .registrationPending,
                intent: .update,
                operationID: UUID().uuidString.lowercased()
            ).operatorStatusLabel,
            "Service stopped; replacement registration is pending"
        )
        XCTAssertEqual(
            SecureFilesystemServiceLifecycleState(
                phase: .registering,
                intent: .enable
            ).recoveryActionLabel,
            "Resume pending registration"
        )
        XCTAssertEqual(
            SecureFilesystemServiceLifecycleState(
                phase: .registrationPending,
                intent: .update
            ).recoveryActionLabel,
            "Register pending replacement"
        )

        let invalid = SecureFilesystemSettingsControlAvailability(
            registrationStatus: .enabled,
            operationState: idle,
            lifecycleState: SecureFilesystemServiceLifecycleState(phase: .stateInvalid)
        )
        XCTAssertFalse(invalid.enable)
        XCTAssertFalse(invalid.update)
        XCTAssertFalse(invalid.disable)
        XCTAssertTrue(invalid.refresh)
        XCTAssertFalse(invalid.reconcile)
        XCTAssertFalse(invalid.lifecycleRecovery)
    }

    @MainActor
    func testControllerPreservesRawStatusWhilePresentingPackagedNotFound() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .notFound)
        let controller = SecureFilesystemServiceController(
            service: service,
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            )
        )

        XCTAssertEqual(controller.status(), .notFound)
        let presentedStatus = await controller.presentedStatus()
        XCTAssertEqual(presentedStatus, .notRegistered)
        XCTAssertEqual(controller.status(), .notFound)
    }

    @MainActor
    func testControllerDistinguishesRegisteredServiceFromOperationalRuntime() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            operationalProbe: SecureFilesystemServiceOperationalProbe(
                operational: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "daemon did not answer"
            )
        )
        let controller = SecureFilesystemServiceController(
            service: service,
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            ),
            operationalTransport: transport
        )

        let health = await controller.operationalHealth(
            paths: AppPaths(home: root.appendingPathComponent("runtime-health")),
            reconcile: false
        )

        XCTAssertEqual(health.registrationStatus, .enabled)
        XCTAssertEqual(health.operationalState, .registeredUnavailable)
        XCTAssertTrue(health.debtStatusAvailable)
        XCTAssertEqual(health.unresolvedDebtCount, 0)
    }

    @MainActor
    func testOperationalHealthRefreshDoesNotReleaseRestoredLocalQuarantineReceipt() async throws {
        let paths = AppPaths(home: root.appendingPathComponent("local-refresh-health"))
        let parent = paths.home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("victim.txt")
        try Data("preserve".utf8).write(to: source)
        let ledger = FilesystemQuarantineLedger(paths: paths)
        let reservation = try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "refresh_observation"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        try FileManager.default.moveItem(
            at: reservation.quarantineURL,
            to: reservation.originalURL
        )
        let receiptBeforeRefresh = try Data(contentsOf: reservation.receiptURL)
        let controller = SecureFilesystemServiceController(
            service: SecureFilesystemServiceRegistrationStub(status: .notRegistered),
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            ),
            operationalTransport: SecureFilesystemTransportStub(status: .notRegistered)
        )

        let refreshed = await controller.operationalHealth(paths: paths)

        XCTAssertTrue(refreshed.debtStatusAvailable)
        XCTAssertEqual(refreshed.localQuarantineOccupied, 1)
        XCTAssertEqual(refreshed.privilegedRecoveryRetained, 0)
        XCTAssertEqual(refreshed.unresolvedDebtCount, 1)
        XCTAssertEqual(refreshed.releasedDuringReconciliation, 0)
        XCTAssertEqual(try Data(contentsOf: reservation.receiptURL), receiptBeforeRefresh)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.home.appendingPathComponent(
                "privileged-filesystem-recovery",
                isDirectory: true
            ).path
        ))

        let reconciled = await controller.operationalHealth(paths: paths, reconcile: true)

        XCTAssertTrue(reconciled.debtStatusAvailable)
        XCTAssertEqual(reconciled.localQuarantineOccupied, 0)
        XCTAssertEqual(reconciled.privilegedRecoveryRetained, 0)
        XCTAssertEqual(reconciled.unresolvedDebtCount, 0)
        XCTAssertEqual(reconciled.releasedDuringReconciliation, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.receiptURL.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("preserve".utf8))
    }

    @MainActor
    func testOperationalHealthRefreshDoesNotReleaseTerminalPrivilegedRecoveryReceipt() async throws {
        let paths = AppPaths(home: root.appendingPathComponent("privileged-refresh-health"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let request = try makeMutationRequest(rootedAt: root)
        let recoveryLedger = SecureFilesystemRecoveryLedger(paths: paths)
        try recoveryLedger.retain(SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("refresh-observation"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        ))
        let receiptURL = paths.home
            .appendingPathComponent("privileged-filesystem-recovery", isDirectory: true)
            .appendingPathComponent("slot-00.json")
        let receiptBeforeRefresh = try Data(contentsOf: receiptURL)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            transactionStatusProvider: { request in
                ForgeFilesystemTransactionStatus(
                    transactionID: request.transactionID,
                    disposition: .committed,
                    code: "ok",
                    message: "committed",
                    terminal: true,
                    committed: true,
                    durabilityConfirmed: true,
                    recoveryRequired: false,
                    acknowledgementRequired: true
                )
            },
            acknowledgeResponseProvider: { _ in
                ForgeFilesystemResponse(
                    ok: true,
                    code: "ok",
                    message: "acknowledged",
                    durabilityConfirmed: true
                )
            }
        )
        let controller = SecureFilesystemServiceController(
            service: SecureFilesystemServiceRegistrationStub(status: .enabled),
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            ),
            operationalTransport: transport
        )

        let refreshed = await controller.operationalHealth(paths: paths, reconcile: false)

        XCTAssertTrue(refreshed.debtStatusAvailable)
        XCTAssertEqual(refreshed.localQuarantineOccupied, 0)
        XCTAssertEqual(refreshed.privilegedRecoveryRetained, 1)
        XCTAssertEqual(refreshed.unresolvedDebtCount, 1)
        XCTAssertEqual(refreshed.releasedDuringReconciliation, 0)
        XCTAssertEqual(transport.queryCallCount, 0)
        XCTAssertEqual(transport.acknowledgeCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptBeforeRefresh)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.home.appendingPathComponent(
                "filesystem-quarantine",
                isDirectory: true
            ).path
        ))

        let reconciled = await controller.operationalHealth(paths: paths, reconcile: true)

        XCTAssertTrue(reconciled.debtStatusAvailable)
        XCTAssertEqual(reconciled.localQuarantineOccupied, 0)
        XCTAssertEqual(reconciled.privilegedRecoveryRetained, 0)
        XCTAssertEqual(reconciled.unresolvedDebtCount, 0)
        XCTAssertEqual(reconciled.releasedDuringReconciliation, 1)
        XCTAssertEqual(transport.queryCallCount, 1)
        XCTAssertEqual(transport.acknowledgeCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    @MainActor
    func testOperationalHealthRefreshRejectsFIFOQuarantineLockWithoutBlockingOrMutation() async throws {
        let paths = AppPaths(home: root.appendingPathComponent("fifo-quarantine-refresh"))
        let parent = paths.home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("victim.txt")
        try Data("preserve".utf8).write(to: source)
        let ledger = FilesystemQuarantineLedger(paths: paths)
        let reservation = try ledger.reserveAndQuarantine(
            parent: parent,
            originalName: source.lastPathComponent,
            parentIdentity: try quarantineIdentity(at: parent),
            leafIdentity: try quarantineIdentity(at: source),
            operation: "fifo_refresh_observation"
        ) { reservation in
            try FileManager.default.moveItem(at: source, to: reservation.quarantineURL)
        }
        let ledgerRoot = reservation.receiptURL.deletingLastPathComponent()
        let lockURL = ledgerRoot.appendingPathComponent(".ledger.lock")
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertEqual(
            lockURL.path.withCString { Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) },
            0
        )
        let receiptBytes = try Data(contentsOf: reservation.receiptURL)
        let quarantineBytes = try Data(contentsOf: reservation.quarantineURL)
        let entries = try directoryEntryNames(at: ledgerRoot)
        let ledgerSnapshot = try filesystemEntrySnapshot(at: ledgerRoot)
        let lockSnapshot = try filesystemEntrySnapshot(at: lockURL)
        let receiptSnapshot = try filesystemEntrySnapshot(at: reservation.receiptURL)
        XCTAssertEqual(lockSnapshot.mode & UInt32(S_IFMT), UInt32(S_IFIFO))
        let unblocker = delayedFIFOReaderUnblock(at: lockURL)
        let controller = SecureFilesystemServiceController(
            service: SecureFilesystemServiceRegistrationStub(status: .notRegistered),
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            ),
            operationalTransport: SecureFilesystemTransportStub(status: .notRegistered)
        )

        let clock = ContinuousClock()
        let started = clock.now
        let refreshed = await controller.operationalHealth(paths: paths, reconcile: false)
        let elapsed = started.duration(to: clock.now)
        unblocker.cancel()
        await unblocker.value

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(refreshed.debtStatusAvailable)
        XCTAssertEqual(refreshed.releasedDuringReconciliation, 0)
        XCTAssertEqual(try directoryEntryNames(at: ledgerRoot), entries)
        XCTAssertEqual(try filesystemEntrySnapshot(at: ledgerRoot), ledgerSnapshot)
        XCTAssertEqual(try filesystemEntrySnapshot(at: lockURL), lockSnapshot)
        XCTAssertEqual(
            try filesystemEntrySnapshot(at: reservation.receiptURL),
            receiptSnapshot
        )
        XCTAssertEqual(try Data(contentsOf: reservation.receiptURL), receiptBytes)
        XCTAssertEqual(try Data(contentsOf: reservation.quarantineURL), quarantineBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.home.appendingPathComponent(
                "privileged-filesystem-recovery",
                isDirectory: true
            ).path
        ))
    }

    @MainActor
    func testOperationalHealthRefreshRejectsFIFORecoveryLockWithoutBlockingOrMutation() async throws {
        let paths = AppPaths(home: root.appendingPathComponent("fifo-recovery-refresh"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let request = try makeMutationRequest(rootedAt: root)
        let recoveryLedger = SecureFilesystemRecoveryLedger(paths: paths)
        try recoveryLedger.retain(SecureFilesystemRecoveryRecord(
            request: request,
            originatingClientID: ClientID("fifo-refresh-observation"),
            rootPath: root.path,
            createdAtMilliseconds: 1
        ))
        let ledgerRoot = paths.home.appendingPathComponent(
            "privileged-filesystem-recovery",
            isDirectory: true
        )
        let lockURL = ledgerRoot.appendingPathComponent(".ledger.lock")
        let receiptURL = ledgerRoot.appendingPathComponent("slot-00.json")
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertEqual(
            lockURL.path.withCString { Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) },
            0
        )
        let receiptBytes = try Data(contentsOf: receiptURL)
        let entries = try directoryEntryNames(at: ledgerRoot)
        let ledgerSnapshot = try filesystemEntrySnapshot(at: ledgerRoot)
        let lockSnapshot = try filesystemEntrySnapshot(at: lockURL)
        let receiptSnapshot = try filesystemEntrySnapshot(at: receiptURL)
        XCTAssertEqual(lockSnapshot.mode & UInt32(S_IFMT), UInt32(S_IFIFO))
        let unblocker = delayedFIFOReaderUnblock(at: lockURL)
        let transport = SecureFilesystemTransportStub(status: .notRegistered)
        let controller = SecureFilesystemServiceController(
            service: SecureFilesystemServiceRegistrationStub(status: .notRegistered),
            packageInspector: SecureFilesystemServicePackageInspectorStub(
                observation: .present
            ),
            operationalTransport: transport
        )

        let clock = ContinuousClock()
        let started = clock.now
        let refreshed = await controller.operationalHealth(paths: paths, reconcile: false)
        let elapsed = started.duration(to: clock.now)
        unblocker.cancel()
        await unblocker.value

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(refreshed.debtStatusAvailable)
        XCTAssertEqual(refreshed.releasedDuringReconciliation, 0)
        XCTAssertEqual(transport.queryCallCount, 0)
        XCTAssertEqual(transport.acknowledgeCallCount, 0)
        XCTAssertEqual(try directoryEntryNames(at: ledgerRoot), entries)
        XCTAssertEqual(try filesystemEntrySnapshot(at: ledgerRoot), ledgerSnapshot)
        XCTAssertEqual(try filesystemEntrySnapshot(at: lockURL), lockSnapshot)
        XCTAssertEqual(try filesystemEntrySnapshot(at: receiptURL), receiptSnapshot)
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.home.appendingPathComponent(
                "filesystem-quarantine",
                isDirectory: true
            ).path
        ))
    }

    func testBundleInspectorReportsPresentForExactPackage() throws {
        let fixture = try makeServicePackage(named: "exact")
        XCTAssertEqual(inspectPackage(fixture), .present)
    }

    func testBundleInspectorReportsMissingForAbsentPackageAndLeaf() throws {
        let absentApplication = root.appendingPathComponent(
            "absent.app",
            isDirectory: true
        )
        XCTAssertEqual(
            SecureFilesystemServiceBundleInspector(
                applicationBundle: absentApplication
            ).inspect(),
            .missing
        )

        let fixture = try makeServicePackage(named: "missing-daemon")
        try FileManager.default.removeItem(at: fixture.daemon)
        XCTAssertEqual(inspectPackage(fixture), .missing)
    }

    func testBundleInspectorRejectsEverySymlinkedPackagePosition() throws {
        let relativePositions = [
            "",
            "Contents",
            "Contents/MacOS",
            "Contents/Library",
            "Contents/Library/LaunchDaemons",
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)",
            "Contents/Library/LaunchDaemons/"
                + ForgeFilesystemProtocolConstants.daemonPlistName,
        ]
        for (index, relativePosition) in relativePositions.enumerated() {
            let fixture = try makeServicePackage(named: "symlink-\(index)")
            let target = relativePosition.isEmpty
                ? fixture.application
                : fixture.application.appendingPathComponent(relativePosition)
            let relocated = root.appendingPathComponent(
                "symlink-target-\(index)",
                isDirectory: target.hasDirectoryPath
            )
            try FileManager.default.moveItem(at: target, to: relocated)
            try FileManager.default.createSymbolicLink(
                at: target,
                withDestinationURL: relocated
            )

            XCTAssertEqual(
                inspectPackage(fixture),
                .invalid,
                "symlink at \(relativePosition.isEmpty ? "application" : relativePosition)"
            )
        }
    }

    func testBundleInspectorRejectsNonExecutableAndMultiplyLinkedDaemon() throws {
        let nonExecutable = try makeServicePackage(named: "non-executable")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: nonExecutable.daemon.path
        )
        XCTAssertEqual(inspectPackage(nonExecutable), .invalid)

        let multiplyLinked = try makeServicePackage(named: "multiply-linked")
        let secondLink = root.appendingPathComponent("daemon-second-link")
        XCTAssertEqual(Darwin.link(multiplyLinked.daemon.path, secondLink.path), 0)
        XCTAssertEqual(inspectPackage(multiplyLinked), .invalid)

        let fifo = try makeServicePackage(named: "daemon-fifo")
        try FileManager.default.removeItem(at: fifo.daemon)
        XCTAssertEqual(Darwin.mkfifo(fifo.daemon.path, 0o600), 0)
        XCTAssertEqual(inspectPackage(fifo), .invalid)
    }

    func testBundleInspectorRejectsOversizedMalformedAndMultiplyLinkedPlist() throws {
        let oversized = try makeServicePackage(named: "oversized-plist")
        try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(
            to: oversized.propertyList
        )
        XCTAssertEqual(inspectPackage(oversized), .invalid)

        let malformed = try makeServicePackage(named: "malformed-plist")
        try Data("not a property list".utf8).write(to: malformed.propertyList)
        XCTAssertEqual(inspectPackage(malformed), .invalid)

        let multiplyLinked = try makeServicePackage(named: "linked-plist")
        let secondLink = root.appendingPathComponent("plist-second-link")
        XCTAssertEqual(
            Darwin.link(multiplyLinked.propertyList.path, secondLink.path),
            0
        )
        XCTAssertEqual(inspectPackage(multiplyLinked), .invalid)

        let fifo = try makeServicePackage(named: "plist-fifo")
        try FileManager.default.removeItem(at: fifo.propertyList)
        XCTAssertEqual(Darwin.mkfifo(fifo.propertyList.path, 0o600), 0)
        XCTAssertEqual(inspectPackage(fifo), .invalid)
    }

    func testBundleInspectorRequiresExactServicePropertyList() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("label", { $0["Label"] = "com.example.wrong" }),
            ("program", { $0["BundleProgram"] = "Contents/MacOS/wrong" }),
            ("user", { $0["UserName"] = "nobody" }),
            ("umask", { $0["Umask"] = 0 }),
            ("mach-service", {
                $0["MachServices"] = [
                    ForgeFilesystemProtocolConstants.serviceName: false,
                ]
            }),
            ("extra-key", { $0["Program"] = "/usr/bin/true" }),
        ]
        for (name, mutate) in mutations {
            let fixture = try makeServicePackage(named: "plist-\(name)")
            var propertyList = exactServicePropertyList()
            mutate(&propertyList)
            try writeServicePropertyList(propertyList, to: fixture.propertyList)
            XCTAssertEqual(inspectPackage(fixture), .invalid, name)
        }
    }

    @MainActor
    func testConcurrentPresentedStatusCallsShareOneInspection() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .notFound)
        let inspector = BlockingSecureFilesystemServicePackageInspector(
            observation: .present
        )
        let controller = SecureFilesystemServiceController(
            service: service,
            packageInspector: inspector
        )
        let first = Task { await controller.presentedStatus() }
        let second = Task { await controller.presentedStatus() }
        await waitForInspectionStart(inspector)
        XCTAssertEqual(inspector.callCount, 1)
        inspector.release()

        let firstStatus = await first.value
        let secondStatus = await second.value
        XCTAssertEqual(firstStatus, .notRegistered)
        XCTAssertEqual(secondStatus, .notRegistered)
        XCTAssertEqual(inspector.callCount, 1)
        let cachedStatus = await controller.presentedStatus()
        XCTAssertEqual(cachedStatus, .notRegistered)
        XCTAssertEqual(inspector.callCount, 1, "present observations must be cached")
    }

    @MainActor
    func testNegativePackageObservationIsRetriedWithoutConcurrentDuplication() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .notFound)
        let inspector = BlockingSecureFilesystemServicePackageInspector(
            observation: .invalid
        )
        let controller = SecureFilesystemServiceController(
            service: service,
            packageInspector: inspector
        )
        let first = Task { await controller.presentedStatus() }
        let second = Task { await controller.presentedStatus() }
        await waitForInspectionStart(inspector)
        XCTAssertEqual(inspector.callCount, 1)
        inspector.release()

        let firstStatus = await first.value
        let secondStatus = await second.value
        XCTAssertEqual(firstStatus, .notFound)
        XCTAssertEqual(secondStatus, .notFound)
        XCTAssertEqual(inspector.callCount, 1)

        let retriedStatus = await controller.presentedStatus()
        XCTAssertEqual(retriedStatus, .notFound)
        XCTAssertEqual(inspector.callCount, 2, "negative observations must be retryable")
    }

    private struct ServicePackageFixture {
        let application: URL
        let daemon: URL
        let propertyList: URL
    }

    private func makeServicePackage(named name: String) throws -> ServicePackageFixture {
        let application = root.appendingPathComponent(
            "Forge-Conductor-\(name).app",
            isDirectory: true
        )
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let launchDaemons = contents.appendingPathComponent(
            "Library/LaunchDaemons",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launchDaemons,
            withIntermediateDirectories: true
        )
        let daemon = macOS.appendingPathComponent(
            ForgeFilesystemProtocolConstants.daemonExecutableName
        )
        let propertyList = launchDaemons.appendingPathComponent(
            ForgeFilesystemProtocolConstants.daemonPlistName
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: daemon)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: daemon.path
        )
        try writeServicePropertyList(
            exactServicePropertyList(),
            to: propertyList
        )
        return ServicePackageFixture(
            application: application,
            daemon: daemon,
            propertyList: propertyList
        )
    }

    private func inspectPackage(
        _ fixture: ServicePackageFixture
    ) -> SecureFilesystemServicePackageObservation {
        SecureFilesystemServiceBundleInspector(
            applicationBundle: fixture.application
        ).inspect()
    }

    private func exactServicePropertyList() -> [String: Any] {
        [
            "BundleProgram": "Contents/MacOS/"
                + ForgeFilesystemProtocolConstants.daemonExecutableName,
            "Label": ForgeFilesystemProtocolConstants.serviceName,
            "MachServices": [ForgeFilesystemProtocolConstants.serviceName: true],
            "Umask": 0o077,
            "UserName": "root",
        ]
    }

    private func writeServicePropertyList(
        _ propertyList: [String: Any],
        to url: URL
    ) throws {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        ).write(to: url)
    }

    @MainActor
    private func waitForInspectionStart(
        _ inspector: BlockingSecureFilesystemServicePackageInspector
    ) async {
        for _ in 0..<1_000 {
            if inspector.callCount > 0 { return }
            await Task.yield()
        }
        XCTFail("service package inspection did not start")
    }

    @MainActor
    func testServiceReinstallWaitsForReapBeforeRegisteringReplacement() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(service: service)
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)

        XCTAssertEqual(service.events, ["unregister_async"])
        service.completeUnregister()

        let status = try await replacement.value
        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
    }

    @MainActor
    func testLifecycleObservationPublishesActiveEnableDisableAndUpdatePhases() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .notRegistered)
        let controller = SecureFilesystemServiceController(service: service)
        let recorder = SecureFilesystemLifecycleObservationRecorder()
        controller.setLifecycleStateObserver { observation in
            recorder.record(observation)
        }

        let enableContext = SecureFilesystemServiceLifecycleObservationContext(
            generation: 1
        )
        let enableStatus = try await controller.register(
            lifecycleObservationContext: enableContext
        )
        XCTAssertEqual(enableStatus, .enabled)
        XCTAssertEqual(
            recorder.phases(for: enableContext),
            [.registering, .settled]
        )

        let disableContext = SecureFilesystemServiceLifecycleObservationContext(
            generation: 2
        )
        let disable = Task {
            try await controller.unregister(
                lifecycleObservationContext: disableContext
            )
        }
        await waitForPendingUnregister(on: service)
        XCTAssertEqual(recorder.phases(for: disableContext), [.unregistering])
        service.completeUnregister()
        let disableStatus = try await disable.value
        XCTAssertEqual(disableStatus, .notRegistered)
        XCTAssertEqual(
            recorder.phases(for: disableContext),
            [.unregistering, .settled]
        )

        service.status = .enabled
        let updateContext = SecureFilesystemServiceLifecycleObservationContext(
            generation: 3
        )
        let update = Task {
            try await controller.reinstall(
                lifecycleObservationContext: updateContext
            )
        }
        await waitForPendingUnregister(on: service)
        XCTAssertEqual(recorder.phases(for: updateContext), [.unregistering])
        service.completeUnregister()
        let updateStatus = try await update.value
        XCTAssertEqual(updateStatus, .enabled)
        XCTAssertEqual(
            recorder.phases(for: updateContext),
            [.unregistering, .registrationPending, .registering, .settled]
        )
    }

    func testLifecycleObservationGateRejectsOlderOperationsAndPhaseRegression() throws {
        var gate = SecureFilesystemServiceLifecycleObservationGate()
        let older = try XCTUnwrap(gate.begin())
        XCTAssertEqual(
            gate.accept(SecureFilesystemServiceLifecycleObservation(
                context: older,
                state: SecureFilesystemServiceLifecycleState(
                    phase: .unregistering,
                    intent: .update
                )
            ))?.phase,
            .unregistering
        )

        let current = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.accept(SecureFilesystemServiceLifecycleObservation(
            context: older,
            state: SecureFilesystemServiceLifecycleState(
                phase: .registrationPending,
                intent: .update
            )
        )))
        XCTAssertEqual(
            gate.accept(SecureFilesystemServiceLifecycleObservation(
                context: current,
                state: SecureFilesystemServiceLifecycleState(
                    phase: .registrationPending,
                    intent: .update
                )
            ))?.phase,
            .registrationPending
        )
        XCTAssertNil(gate.accept(SecureFilesystemServiceLifecycleObservation(
            context: current,
            state: SecureFilesystemServiceLifecycleState(
                phase: .outcomeUncertain,
                intent: .update
            )
        )))
        XCTAssertEqual(
            gate.accept(SecureFilesystemServiceLifecycleObservation(
                context: current,
                state: .settled
            ))?.phase,
            .settled
        )
        XCTAssertNil(gate.accept(SecureFilesystemServiceLifecycleObservation(
            context: current,
            state: SecureFilesystemServiceLifecycleState(
                phase: .registering,
                intent: .update
            )
        )))
    }

    @MainActor
    func testServiceReinstallFailureDoesNotRegisterReplacement() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(service: service)
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)
        service.completeUnregister(error: NSError(
            domain: "SecureFilesystemServiceRegistrationStub",
            code: 1
        ))

        do {
            _ = try await replacement.value
            XCTFail("unregister failure must prevent replacement registration")
        } catch {
            XCTAssertEqual(service.events, ["unregister_async"])
            let state = await controller.lifecycleState()
            XCTAssertEqual(state.phase, .settled)
        }
    }

    @MainActor
    func testServiceReinstallTimesOutWhenReapCallbackIsMissing() async {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let lifecycleFence = root.appendingPathComponent("reinstall-timeout-fence.json")
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)
        await waitForPendingTimeout(on: timeout)

        timeout.fire()

        do {
            _ = try await replacement.value
            XCTFail("a missing reap callback must time out without registering")
        } catch SecureFilesystemServiceLifecycleError.unregisterTimedOut {
            XCTAssertEqual(service.events, ["unregister_async"])
            let state = await controller.lifecycleState()
            XCTAssertEqual(state.phase, .outcomeUncertain)
            XCTAssertEqual(state.intent, .update)
            XCTAssertNotNil(state.operationID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lifecycleFence.path))
        } catch {
            XCTFail("unexpected reinstall error: \(error)")
        }
    }

    @MainActor
    func testLateReapCallbackAfterTimeoutDoesNotRegisterReplacement() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let lifecycleFence = root.appendingPathComponent("late-callback-fence.json")
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)
        await waitForPendingTimeout(on: timeout)
        timeout.fire()

        do {
            _ = try await replacement.value
            XCTFail("a timed-out reinstall must fail")
        } catch SecureFilesystemServiceLifecycleError.unregisterTimedOut {
            let uncertainState = await controller.lifecycleState()
            XCTAssertEqual(uncertainState.phase, .outcomeUncertain)
            do {
                _ = try await controller.register()
                XCTFail("an unresolved stop must block a successor registration")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                XCTAssertEqual(service.events, ["unregister_async"])
            } catch {
                XCTFail("unexpected successor error: \(error)")
            }
            service.completeUnregister()
            _ = await waitForLifecyclePhase(.registrationPending, on: controller)
            XCTAssertEqual(service.events, ["unregister_async"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: lifecycleFence.path))
            let recovered = try await controller.recoverInterruptedUnregister()
            XCTAssertEqual(recovered, .enabled)
            _ = await waitForLifecyclePhase(.settled, on: controller)
            XCTAssertEqual(service.events, ["unregister_async", "register"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleFence.path))
        } catch {
            XCTFail("unexpected reinstall error: \(error)")
        }
    }

    @MainActor
    func testCancelledServiceReinstallIgnoresLateReapCallback() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let lifecycleFence = root.appendingPathComponent("cancelled-fence.json")
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)
        await waitForPendingTimeout(on: timeout)

        replacement.cancel()
        do {
            _ = try await replacement.value
            XCTFail("a cancelled reinstall must not register a replacement")
        } catch is CancellationError {
            let uncertainState = await controller.lifecycleState()
            XCTAssertEqual(uncertainState.phase, .outcomeUncertain)
            do {
                _ = try await controller.reinstall()
                XCTFail("cancellation must leave successor lifecycle work fenced")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                XCTAssertEqual(service.events, ["unregister_async"])
            } catch {
                XCTFail("unexpected successor error: \(error)")
            }
            service.completeUnregister()
            timeout.fire()
            _ = await waitForLifecyclePhase(.registrationPending, on: controller)
            XCTAssertEqual(service.events, ["unregister_async"])
            let recovered = try await controller.recoverInterruptedUnregister()
            XCTAssertEqual(recovered, .enabled)
            _ = await waitForLifecyclePhase(.settled, on: controller)
            XCTAssertEqual(service.events, ["unregister_async", "register"])
        } catch {
            XCTFail("unexpected reinstall error: \(error)")
        }
    }

    @MainActor
    func testTimeoutClaimThenCallbackBeforeUncertainWritePreservesPendingRegistration() async throws {
        let lifecycleFence = root.appendingPathComponent("timeout-callback-first.json")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let uncertaintyGate = SecureFilesystemUncertaintyGate()
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence,
            beforeUncertaintyPersistence: {
                await uncertaintyGate.enterAndWait()
            }
        )
        let recorder = SecureFilesystemLifecycleObservationRecorder()
        controller.setLifecycleStateObserver { observation in
            recorder.record(observation)
        }
        let context = SecureFilesystemServiceLifecycleObservationContext(
            generation: 1
        )
        let update = Task {
            try await controller.reinstall(lifecycleObservationContext: context)
        }
        await waitForPendingUnregister(on: service)
        await waitForPendingTimeout(on: timeout)

        timeout.fire()
        await waitForUncertaintyGate(uncertaintyGate)
        service.completeUnregister()
        _ = await waitForLifecyclePhase(.registrationPending, on: controller)
        await uncertaintyGate.release()

        do {
            _ = try await update.value
            XCTFail("the claimed timeout must remain the caller result")
        } catch SecureFilesystemServiceLifecycleError.unregisterTimedOut {
            let pendingState = await controller.lifecycleState()
            XCTAssertEqual(pendingState.phase, .registrationPending)
            XCTAssertEqual(service.events, ["unregister_async"])
            let observedPhases = recorder.phases(for: context)
            XCTAssertEqual(observedPhases.first, .unregistering)
            XCTAssertTrue(observedPhases.contains(.registrationPending))
            XCTAssertEqual(observedPhases.last, .registrationPending)
            XCTAssertFalse(observedPhases.contains(.outcomeUncertain))
        }
        let recoveredStatus = try await controller.recoverInterruptedLifecycle()
        XCTAssertEqual(recoveredStatus, .enabled)
        let recoveredState = await controller.lifecycleState()
        XCTAssertEqual(recoveredState.phase, .settled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
    }

    @MainActor
    func testCancellationClaimThenCallbackBeforeUncertainWritePreservesPendingRegistration() async throws {
        let lifecycleFence = root.appendingPathComponent("cancel-callback-first.json")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let uncertaintyGate = SecureFilesystemUncertaintyGate()
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence,
            beforeUncertaintyPersistence: {
                await uncertaintyGate.enterAndWait()
            }
        )
        let recorder = SecureFilesystemLifecycleObservationRecorder()
        controller.setLifecycleStateObserver { observation in
            recorder.record(observation)
        }
        let context = SecureFilesystemServiceLifecycleObservationContext(
            generation: 1
        )
        let update = Task {
            try await controller.reinstall(lifecycleObservationContext: context)
        }
        await waitForPendingUnregister(on: service)

        update.cancel()
        await waitForUncertaintyGate(uncertaintyGate)
        service.completeUnregister()
        _ = await waitForLifecyclePhase(.registrationPending, on: controller)
        await uncertaintyGate.release()

        do {
            _ = try await update.value
            XCTFail("the claimed cancellation must remain the caller result")
        } catch is CancellationError {
            let pendingState = await controller.lifecycleState()
            XCTAssertEqual(pendingState.phase, .registrationPending)
            XCTAssertEqual(service.events, ["unregister_async"])
            let observedPhases = recorder.phases(for: context)
            XCTAssertEqual(observedPhases.first, .unregistering)
            XCTAssertTrue(observedPhases.contains(.registrationPending))
            XCTAssertEqual(observedPhases.last, .registrationPending)
            XCTAssertFalse(observedPhases.contains(.outcomeUncertain))
        }
        let recoveredStatus = try await controller.recoverInterruptedLifecycle()
        XCTAssertEqual(recoveredStatus, .enabled)
        let recoveredState = await controller.lifecycleState()
        XCTAssertEqual(recoveredState.phase, .settled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
    }

    @MainActor
    func testConcurrentDisableFailsClosedDuringPendingServiceReinstall() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(service: service)
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)

        do {
            _ = try await controller.unregister()
            XCTFail("a second unregister must not overlap a pending reinstall")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertEqual(service.events, ["unregister_async"])
        }
        service.completeUnregister()
        let replacementStatus = try await replacement.value
        XCTAssertEqual(replacementStatus, .enabled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
    }

    @MainActor
    func testRegisterLeaseBlocksConcurrentDisableAndUpdateAcrossControllers() async throws {
        let lifecycleFence = root.appendingPathComponent("register-race-fence.json")
        let registeringService = SecureFilesystemServiceRegistrationStub(
            status: .notRegistered,
            blockRegistration: true
        )
        let registeringController = SecureFilesystemServiceController(
            service: registeringService,
            lifecycleFenceURL: lifecycleFence
        )
        let registration = Task { try await registeringController.register() }
        await waitForRegistrationStart(on: registeringService)
        let registeringState = await registeringController.lifecycleState()
        XCTAssertEqual(registeringState.phase, .registering)
        XCTAssertFalse(registeringService.registrationWasOnMainThread ?? true)

        let competingService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let competingController = SecureFilesystemServiceController(
            service: competingService,
            lifecycleFenceURL: lifecycleFence
        )
        do {
            _ = try await competingController.unregister()
            XCTFail("Disable must not overlap a live registration lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(competingService.events.isEmpty)
        }
        do {
            _ = try await competingController.reinstall()
            XCTFail("Update must not overlap a live registration lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(competingService.events.isEmpty)
        }

        let mainActorProgress = SynchronizedBoolean()
        Task { @MainActor in mainActorProgress.set(true) }
        for _ in 0..<100 where !mainActorProgress.value { await Task.yield() }
        XCTAssertTrue(mainActorProgress.value, "registration must not block the main actor")

        registeringService.releaseRegistration()
        let registrationStatus = try await registration.value
        XCTAssertEqual(registrationStatus, .enabled)
        XCTAssertEqual(registeringService.events, ["register"])
        let settledState = await registeringController.lifecycleState()
        XCTAssertEqual(settledState.phase, .settled)
    }

    @MainActor
    func testRegisterTimeoutRetainsLeaseUntilLateResolutionThenReleasesIt() async throws {
        let lifecycleFence = root.appendingPathComponent("register-timeout-fence.json")
        let service = SecureFilesystemServiceRegistrationStub(
            status: .notRegistered,
            blockRegistration: true
        )
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let recorder = SecureFilesystemLifecycleObservationRecorder()
        controller.setLifecycleStateObserver { observation in
            recorder.record(observation)
        }
        let context = SecureFilesystemServiceLifecycleObservationContext(
            generation: 1
        )
        let registration = Task {
            try await controller.register(lifecycleObservationContext: context)
        }
        await waitForRegistrationStart(on: service)
        await waitForPendingTimeout(on: timeout)
        XCTAssertEqual(recorder.phases(for: context), [.registering])

        timeout.fire()
        do {
            _ = try await registration.value
            XCTFail("a blocked registration must return its bounded timeout")
        } catch SecureFilesystemServiceLifecycleError.registerTimedOut {
            let timedOutState = await controller.lifecycleState()
            XCTAssertEqual(timedOutState.phase, .registering)
        } catch {
            XCTFail("unexpected registration timeout error: \(error)")
        }

        let contenderService = SecureFilesystemServiceRegistrationStub(
            status: .notRegistered
        )
        let contender = SecureFilesystemServiceController(
            service: contenderService,
            lifecycleFenceURL: lifecycleFence
        )
        for operation in ["register", "disable", "update"] {
            do {
                switch operation {
                case "register": _ = try await contender.register()
                case "disable": _ = try await contender.unregister()
                default: _ = try await contender.reinstall()
                }
                XCTFail("\(operation) must not pass a timed-out live registration lease")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                XCTAssertTrue(contenderService.events.isEmpty)
            } catch {
                XCTFail("unexpected \(operation) contender error: \(error)")
            }
        }

        service.releaseRegistration()
        _ = await waitForLifecyclePhase(.settled, on: controller)
        await waitForObservedLifecyclePhase(.settled, context: context, recorder: recorder)
        XCTAssertEqual(recorder.phases(for: context), [.registering, .settled])
        XCTAssertEqual(service.events, ["register"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleFence.path))

        let successorStatus = try await contender.register()
        XCTAssertEqual(successorStatus, .enabled)
        XCTAssertEqual(contenderService.events, ["register"])
    }

    @MainActor
    func testRegisterCancellationRetainsLeaseUntilLateResolutionThenReleasesIt() async throws {
        let lifecycleFence = root.appendingPathComponent("register-cancel-fence.json")
        let service = SecureFilesystemServiceRegistrationStub(
            status: .notRegistered,
            blockRegistration: true
        )
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let recorder = SecureFilesystemLifecycleObservationRecorder()
        controller.setLifecycleStateObserver { observation in
            recorder.record(observation)
        }
        let context = SecureFilesystemServiceLifecycleObservationContext(
            generation: 1
        )
        let registration = Task {
            try await controller.register(lifecycleObservationContext: context)
        }
        await waitForRegistrationStart(on: service)
        await waitForPendingTimeout(on: timeout)

        registration.cancel()
        do {
            _ = try await registration.value
            XCTFail("a cancelled registration must return cancellation")
        } catch is CancellationError {
            let cancelledState = await controller.lifecycleState()
            XCTAssertEqual(cancelledState.phase, .registering)
            XCTAssertFalse(timeout.hasPendingAction)
        } catch {
            XCTFail("unexpected registration cancellation error: \(error)")
        }

        let contenderService = SecureFilesystemServiceRegistrationStub(
            status: .notRegistered
        )
        let contender = SecureFilesystemServiceController(
            service: contenderService,
            lifecycleFenceURL: lifecycleFence
        )
        do {
            _ = try await contender.register()
            XCTFail("a cancellation must not release the in-flight registration lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(contenderService.events.isEmpty)
        } catch {
            XCTFail("unexpected cancelled-registration contender error: \(error)")
        }

        service.releaseRegistration()
        _ = await waitForLifecyclePhase(.settled, on: controller)
        await waitForObservedLifecyclePhase(.settled, context: context, recorder: recorder)
        XCTAssertEqual(recorder.phases(for: context), [.registering, .settled])
        XCTAssertEqual(service.events, ["register"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleFence.path))

        let successorStatus = try await contender.register()
        XCTAssertEqual(successorStatus, .enabled)
        XCTAssertEqual(contenderService.events, ["register"])
    }

    @MainActor
    func testDisableLeaseBlocksConcurrentRegisterAndUpdateAcrossControllers() async throws {
        let lifecycleFence = root.appendingPathComponent("disable-race-fence.json")
        let disablingService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let disablingController = SecureFilesystemServiceController(
            service: disablingService,
            lifecycleFenceURL: lifecycleFence
        )
        let disable = Task { try await disablingController.unregister() }
        await waitForPendingUnregister(on: disablingService)

        let competingService = SecureFilesystemServiceRegistrationStub(status: .notRegistered)
        let competingController = SecureFilesystemServiceController(
            service: competingService,
            lifecycleFenceURL: lifecycleFence
        )
        do {
            _ = try await competingController.register()
            XCTFail("Register must not overlap a live Disable lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(competingService.events.isEmpty)
        }
        do {
            _ = try await competingController.reinstall()
            XCTFail("Update must not overlap a live Disable lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(competingService.events.isEmpty)
        }

        disablingService.completeUnregister()
        let disableStatus = try await disable.value
        XCTAssertEqual(disableStatus, .notRegistered)
        XCTAssertEqual(disablingService.events, ["unregister_async"])
    }

    @MainActor
    func testLiveReinstallLeaseBlocksRecoveryWithoutDispatchingSuccessor() async throws {
        let lifecycleFence = root.appendingPathComponent("reinstall-recovery-race.json")
        let updateService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let updateController = SecureFilesystemServiceController(
            service: updateService,
            lifecycleFenceURL: lifecycleFence
        )
        let update = Task { try await updateController.reinstall() }
        await waitForPendingUnregister(on: updateService)

        let recoveryService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let recoveryController = SecureFilesystemServiceController(
            service: recoveryService,
            lifecycleFenceURL: lifecycleFence
        )
        do {
            _ = try await recoveryController.recoverInterruptedUnregister()
            XCTFail("recovery must not take over a live Reinstall lease")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(recoveryService.events.isEmpty)
        }

        updateService.completeUnregister()
        let updateStatus = try await update.value
        XCTAssertEqual(updateStatus, .enabled)
        XCTAssertEqual(updateService.events, ["unregister_async", "register"])
    }

    @MainActor
    func testRemovedActiveLifecycleRecordFailsClosedWithoutReplacementRegistration() async throws {
        let lifecycleFence = root.appendingPathComponent("removed-active-record.json")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )
        let update = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)
        try FileManager.default.removeItem(at: lifecycleFence)

        service.completeUnregister()
        do {
            _ = try await update.value
            XCTFail("a removed exact record must stop replacement registration")
        } catch SecureFilesystemServiceLifecycleError.lifecycleStateInvalid {
            XCTAssertEqual(service.events, ["unregister_async"])
            let invalidState = await controller.lifecycleState()
            XCTAssertEqual(invalidState.phase, .stateInvalid)
        }
    }

    @MainActor
    func testReplacedActiveLifecycleRecordIsSupersededWithoutReplacementRegistration() async throws {
        let lifecycleFence = root.appendingPathComponent("replaced-active-record.json")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )
        let update = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)

        var replacement = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: lifecycleFence))
                as? [String: Any]
        )
        replacement["attemptID"] = UUID().uuidString.lowercased()
        try OwnerOnlyAtomicFile.write(
            JSONSerialization.data(withJSONObject: replacement, options: [.sortedKeys]),
            to: lifecycleFence
        )

        service.completeUnregister()
        do {
            _ = try await update.value
            XCTFail("a replaced exact record must supersede the old callback")
        } catch SecureFilesystemServiceLifecycleError.superseded {
            XCTAssertEqual(service.events, ["unregister_async"])
            let invalidState = await controller.lifecycleState()
            XCTAssertEqual(invalidState.phase, .stateInvalid)
        }
    }

    @MainActor
    func testReplacedLifecycleLockFailsClosedForOwnerAndRecoveryContender() async throws {
        let lifecycleFence = root.appendingPathComponent("replaced-active-lock.json")
        let lockURL = lifecycleFence.appendingPathExtension("lock")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )
        let update = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)

        try FileManager.default.removeItem(at: lockURL)
        try OwnerOnlyAtomicFile.write(Data(), to: lockURL)

        let contenderService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let contender = SecureFilesystemServiceController(
            service: contenderService,
            lifecycleFenceURL: lifecycleFence
        )
        let contenderState = await contender.lifecycleState()
        XCTAssertEqual(contenderState.phase, .stateInvalid)
        do {
            _ = try await contender.recoverInterruptedUnregister()
            XCTFail("a replacement lock inode must not authorize recovery")
        } catch SecureFilesystemServiceLifecycleError.lifecycleStateInvalid {
            XCTAssertTrue(contenderService.events.isEmpty)
        }

        service.completeUnregister()
        do {
            _ = try await update.value
            XCTFail("the original owner must reject an unlinked lease inode")
        } catch SecureFilesystemServiceLifecycleError.lifecycleStateInvalid {
            XCTAssertEqual(service.events, ["unregister_async"])
            let invalidState = await controller.lifecycleState()
            XCTAssertEqual(invalidState.phase, .stateInvalid)
        }
    }

    @MainActor
    func testServiceDisableWaitsForCompletionAndUsesNoSynchronousUnregister() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(service: service)
        let disable = Task { try await controller.unregister() }
        await waitForPendingUnregister(on: service)

        XCTAssertEqual(service.events, ["unregister_async"])
        let unregisteringState = await controller.lifecycleState()
        XCTAssertEqual(unregisteringState.phase, .unregistering)
        service.completeUnregister()

        let disableStatus = try await disable.value
        XCTAssertEqual(disableStatus, .notRegistered)
        let settledState = await controller.lifecycleState()
        XCTAssertEqual(settledState.phase, .settled)
        XCTAssertEqual(service.events, ["unregister_async"])
    }

    @MainActor
    func testServiceDisableTimeoutRetainsDurableFenceAndBlocksRegistration() async {
        let lifecycleFence = root.appendingPathComponent("disable-timeout-fence.json")
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let timeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let controller = SecureFilesystemServiceController(
            service: service,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: timeout,
            lifecycleFenceURL: lifecycleFence
        )
        let disable = Task { try await controller.unregister() }
        await waitForPendingUnregister(on: service)
        await waitForPendingTimeout(on: timeout)
        timeout.fire()

        do {
            _ = try await disable.value
            XCTFail("Disable must not report completion without the macOS callback")
        } catch SecureFilesystemServiceLifecycleError.unregisterTimedOut {
            let state = await controller.lifecycleState()
            XCTAssertEqual(state.phase, .outcomeUncertain)
            XCTAssertEqual(state.intent, .disable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lifecycleFence.path))
        } catch {
            XCTFail("unexpected disable timeout error: \(error)")
        }
        do {
            _ = try await controller.register()
            XCTFail("a timed-out Disable must fence a successor registration")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertEqual(service.events, ["unregister_async"])
        } catch {
            XCTFail("unexpected successor error: \(error)")
        }
    }

    @MainActor
    func testLivePredecessorLeaseBlocksRelaunchRecoveryAndEverySuccessorOperation() async throws {
        let paths = AppPaths(home: root.appendingPathComponent("relaunch-app-home"))
        try paths.ensureLayout()
        let originalService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let originalTimeout = SecureFilesystemServiceTimeoutSchedulerStub()
        let originalController = SecureFilesystemServiceController(
            service: originalService,
            unregisterTimeoutSeconds: 1,
            timeoutScheduler: originalTimeout
        )
        let initialState = await originalController.configureLifecycleFence(paths: paths)
        XCTAssertEqual(initialState, .settled)
        let originalReplacement = Task { try await originalController.reinstall() }
        await waitForPendingUnregister(on: originalService)
        await waitForPendingTimeout(on: originalTimeout)
        originalTimeout.fire()
        do {
            _ = try await originalReplacement.value
            XCTFail("the original replacement must time out")
        } catch SecureFilesystemServiceLifecycleError.unregisterTimedOut {
            let uncertainState = await originalController.lifecycleState()
            XCTAssertEqual(uncertainState.phase, .outcomeUncertain)
        } catch {
            XCTFail("unexpected original error: \(error)")
        }

        let relaunchedService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let relaunchedController = SecureFilesystemServiceController(
            service: relaunchedService
        )
        let relaunchedState = await relaunchedController.configureLifecycleFence(paths: paths)
        XCTAssertEqual(relaunchedState.phase, .outcomeUncertain)

        for operation in ["register", "reinstall", "disable"] {
            do {
                switch operation {
                case "register": _ = try await relaunchedController.register()
                case "reinstall": _ = try await relaunchedController.reinstall()
                default: _ = try await relaunchedController.unregister()
                }
                XCTFail("\(operation) must fail closed before recovery")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                XCTAssertTrue(relaunchedService.events.isEmpty)
            } catch {
                XCTFail("unexpected \(operation) error: \(error)")
            }
        }

        do {
            _ = try await relaunchedController.recoverInterruptedUnregister()
            XCTFail("recovery must not take over while the predecessor lease is live")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(relaunchedService.events.isEmpty)
        } catch {
            XCTFail("unexpected live-predecessor recovery error: \(error)")
        }

        originalService.completeUnregister()
        _ = await waitForLifecyclePhase(.registrationPending, on: relaunchedController)
        // Both stubs model one global SMAppService status; reflect the completed
        // predecessor reap in the relaunched process's observation.
        relaunchedService.status = .notRegistered
        do {
            let registrationStatus = try await relaunchedController
                .recoverInterruptedLifecycle()
            XCTAssertEqual(registrationStatus, .enabled)
        } catch {
            XCTFail("the pending replacement should recover after lease release: \(error)")
        }
        let recoveredState = await relaunchedController.lifecycleState()
        XCTAssertEqual(recoveredState.phase, .settled)
        XCTAssertEqual(relaunchedService.events, ["register"])
    }

    @MainActor
    func testUpdateRecoveryAdvancesThroughPendingRegistrationWithoutSilentDisable() async throws {
        let lifecycleFence = root.appendingPathComponent("two-phase-update-recovery.json")
        try seedLifecycleRecord(
            at: lifecycleFence,
            intent: "update",
            phase: "outcome_uncertain"
        )
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )

        let reapRecovery = Task {
            try await controller.recoverInterruptedUnregister()
        }
        await waitForPendingUnregister(on: service)
        service.completeUnregister()
        let reapStatus = try await reapRecovery.value
        XCTAssertEqual(reapStatus, .notRegistered)
        let pendingState = await controller.lifecycleState()
        XCTAssertEqual(pendingState.phase, .registrationPending)
        XCTAssertEqual(service.events, ["unregister_async"])

        let registrationStatus = try await controller.recoverInterruptedUnregister()
        XCTAssertEqual(registrationStatus, .enabled)
        let settledState = await controller.lifecycleState()
        XCTAssertEqual(settledState.phase, .settled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
    }

    @MainActor
    func testBoundedAutomaticRestartRecoveryCompletesBothUpdatePhases() async throws {
        let lifecycleFence = root.appendingPathComponent("automatic-update-recovery.json")
        try seedLifecycleRecord(
            at: lifecycleFence,
            intent: "update",
            phase: "outcome_uncertain"
        )
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )

        let recovery = Task {
            try await controller.recoverInterruptedLifecycle()
        }
        await waitForPendingUnregister(on: service)
        service.completeUnregister()

        let recoveryStatus = try await recovery.value
        XCTAssertEqual(recoveryStatus, .enabled)
        let settledState = await controller.lifecycleState()
        XCTAssertEqual(settledState.phase, .settled)
        XCTAssertEqual(service.events, ["unregister_async", "register"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lifecycleFence.path))
    }

    @MainActor
    func testConcurrentRecoveryContendersDispatchExactlyOneUnregister() async throws {
        let lifecycleFence = root.appendingPathComponent("concurrent-recovery.json")
        try seedLifecycleRecord(
            at: lifecycleFence,
            intent: "disable",
            phase: "outcome_uncertain"
        )
        let firstService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let secondService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let firstController = SecureFilesystemServiceController(
            service: firstService,
            lifecycleFenceURL: lifecycleFence
        )
        let secondController = SecureFilesystemServiceController(
            service: secondService,
            lifecycleFenceURL: lifecycleFence
        )
        let firstRecovery = Task { @MainActor () -> Result<
            SecureFilesystemServiceStatus, Error
        > in
            do { return .success(try await firstController.recoverInterruptedUnregister()) }
            catch { return .failure(error) }
        }
        let secondRecovery = Task { @MainActor () -> Result<
            SecureFilesystemServiceStatus, Error
        > in
            do { return .success(try await secondController.recoverInterruptedUnregister()) }
            catch { return .failure(error) }
        }

        for _ in 0..<1_000 {
            if firstService.pendingUnregisterCount + secondService.pendingUnregisterCount == 1 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(
            firstService.pendingUnregisterCount + secondService.pendingUnregisterCount,
            1
        )

        let firstWon = firstService.hasPendingUnregister
        let losingResult = await (firstWon ? secondRecovery : firstRecovery).value
        guard case .failure(let losingError) = losingResult,
              let lifecycleError = losingError as? SecureFilesystemServiceLifecycleError,
              case .lifecycleResolutionRequired = lifecycleError else {
            return XCTFail("the second recovery contender did not fail closed")
        }

        if firstWon {
            firstService.completeUnregister()
        } else {
            secondService.completeUnregister()
        }
        let winningResult = await (firstWon ? firstRecovery : secondRecovery).value
        guard case .success(.notRegistered) = winningResult else {
            return XCTFail("the lease owner did not complete the single recovery dispatch")
        }
        XCTAssertEqual(firstService.events.count + secondService.events.count, 1)
        let firstState = await firstController.lifecycleState()
        let secondState = await secondController.lifecycleState()
        XCTAssertEqual(firstState.phase, .settled)
        XCTAssertEqual(secondState.phase, .settled)
    }

    @MainActor
    func testRecoveryAttemptLimitFailsClosedWithoutServiceDispatch() async throws {
        let lifecycleFence = root.appendingPathComponent("bounded-recovery.json")
        try seedLifecycleRecord(
            at: lifecycleFence,
            intent: "disable",
            phase: "outcome_uncertain",
            attemptNumber: 8
        )
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )

        let initialState = await controller.lifecycleState()
        XCTAssertEqual(initialState.phase, .outcomeUncertain)
        do {
            _ = try await controller.recoverInterruptedUnregister()
            XCTFail("the bounded recovery attempt limit must block another dispatch")
        } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
            XCTAssertTrue(service.events.isEmpty)
            let boundedState = await controller.lifecycleState()
            XCTAssertEqual(boundedState.phase, .outcomeUncertain)
        }
    }

    func testLifecycleXCTestFixtureContinuouslyDrainsAndCapsBothOutputStreams() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FORGE_FILESYSTEM_LIFECYCLE_OUTPUT_PRESSURE"] == "child" {
            guard let markerPath = environment[
                "FORGE_FILESYSTEM_LIFECYCLE_OUTPUT_MARKER"
            ] else {
                throw SecureFilesystemLifecycleProcessError.failed(
                    "output-pressure marker path is missing"
                )
            }
            let output = Data(repeating: UInt8(ascii: "o"), count: 512 * 1_024)
            let error = Data(repeating: UInt8(ascii: "e"), count: 512 * 1_024)
            FileHandle.standardOutput.write(output)
            FileHandle.standardError.write(error)
            try OwnerOnlyAtomicFile.write(
                Data("drained".utf8),
                to: URL(fileURLWithPath: markerPath)
            )
            return
        }

        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        let testIdentifier = "\(reflectedName)/\(methodName)"
        let marker = root.appendingPathComponent("output-pressure-ready")
        let child = try launchSecureFilesystemLifecycleXCTestFixture(
            testIdentifier: testIdentifier,
            environment: [
                "FORGE_FILESYSTEM_LIFECYCLE_OUTPUT_PRESSURE": "child",
                "FORGE_FILESYSTEM_LIFECYCLE_OUTPUT_MARKER": marker.path,
            ]
        )
        defer { child.close() }

        try waitForSecureFilesystemLifecycleMarker(marker, child: child, timeout: 5)
        try waitForSecureFilesystemLifecycleXCTestFixtureExit(child, timeout: 5)
        let diagnostics = child.diagnostics()
        XCTAssertTrue(diagnostics.contains("stdout_truncated=true"), diagnostics)
        XCTAssertTrue(diagnostics.contains("stderr_truncated=true"), diagnostics)
        XCTAssertTrue(diagnostics.contains("stdout_bytes=65536"), diagnostics)
        XCTAssertTrue(diagnostics.contains("stderr_bytes=65536"), diagnostics)
        XCTAssertTrue(diagnostics.contains("stdout_drain_timed_out=false"), diagnostics)
        XCTAssertTrue(diagnostics.contains("stderr_drain_timed_out=false"), diagnostics)
    }

    @MainActor
    func testLifecycleLeaseBlocksLiveProcessAndRecoversCrashPhases() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let role = environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_ROLE"] {
            guard let fencePath = environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_FENCE"],
                  let readyPath = environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_READY"] else {
                throw SecureFilesystemLifecycleProcessError.failed(
                    "lifecycle child paths are missing"
                )
            }
            try await runLifecycleProcessChild(
                role: role,
                lifecycleFence: URL(fileURLWithPath: fencePath),
                ready: URL(fileURLWithPath: readyPath)
            )
            return
        }

        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        let testIdentifier = "\(reflectedName)/\(methodName)"

        for role in ["unregistering", "registering", "registration-pending"] {
            let lifecycleFence = root.appendingPathComponent("process-\(role).json")
            let ready = root.appendingPathComponent("process-\(role)-ready")
            let child = try launchSecureFilesystemLifecycleXCTestFixture(
                testIdentifier: testIdentifier,
                environment: [
                    "FORGE_FILESYSTEM_LIFECYCLE_TEST_ROLE": role,
                    "FORGE_FILESYSTEM_LIFECYCLE_TEST_FENCE": lifecycleFence.path,
                    "FORGE_FILESYSTEM_LIFECYCLE_TEST_READY": ready.path,
                ]
            )
            defer { child.close() }
            try waitForSecureFilesystemLifecycleMarker(
                ready,
                child: child,
                timeout: 5
            )

            let liveContenderService = SecureFilesystemServiceRegistrationStub(
                status: role == "unregistering" ? .enabled : .notRegistered
            )
            let liveContender = SecureFilesystemServiceController(
                service: liveContenderService,
                lifecycleFenceURL: lifecycleFence
            )
            do {
                _ = try await liveContender.recoverInterruptedUnregister()
                XCTFail("\(role) recovery must not take over a live process lease")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                XCTAssertTrue(liveContenderService.events.isEmpty)
            }

            let termination = try forceKillSecureFilesystemLifecycleXCTestFixture(
                child,
                timeout: 2
            )
            XCTAssertEqual(termination.reason, .uncaughtSignal)
            XCTAssertEqual(termination.status, SIGKILL)

            switch role {
            case "unregistering":
                let recovery = Task {
                    try await liveContender.recoverInterruptedUnregister()
                }
                await waitForPendingUnregister(on: liveContenderService)
                liveContenderService.completeUnregister()
                let recoveryStatus = try await recovery.value
                XCTAssertEqual(recoveryStatus, .notRegistered)
                XCTAssertEqual(liveContenderService.events, ["unregister_async"])
            case "registering", "registration-pending":
                let recoveryStatus = try await liveContender
                    .recoverInterruptedUnregister()
                XCTAssertEqual(recoveryStatus, .enabled)
                XCTAssertEqual(liveContenderService.events, ["register"])
            default:
                XCTFail("unexpected lifecycle fixture role \(role)")
            }
            let recoveredState = await liveContender.lifecycleState()
            XCTAssertEqual(recoveredState.phase, .settled)
        }
    }

    @MainActor
    func testDistinctProcessRecoveryContendersDispatchExactlyOnce() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_ROLE"]
            == "recovery-contender" {
            guard let fencePath = environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_FENCE"],
                  let readyPath = environment["FORGE_FILESYSTEM_LIFECYCLE_TEST_READY"] else {
                throw SecureFilesystemLifecycleProcessError.failed(
                    "recovery contender paths are missing"
                )
            }
            try await runLifecycleRecoveryContenderChild(
                lifecycleFence: URL(fileURLWithPath: fencePath),
                ready: URL(fileURLWithPath: readyPath)
            )
            return
        }

        let lifecycleFence = root.appendingPathComponent("process-recovery-race.json")
        try seedLifecycleRecord(
            at: lifecycleFence,
            intent: "disable",
            phase: "outcome_uncertain"
        )
        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        let testIdentifier = "\(reflectedName)/\(methodName)"
        let firstReady = root.appendingPathComponent("first-recovery-contender")
        let secondReady = root.appendingPathComponent("second-recovery-contender")
        let firstChild = try launchSecureFilesystemLifecycleXCTestFixture(
            testIdentifier: testIdentifier,
            environment: [
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_ROLE": "recovery-contender",
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_FENCE": lifecycleFence.path,
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_READY": firstReady.path,
            ]
        )
        defer { firstChild.close() }
        let secondChild = try launchSecureFilesystemLifecycleXCTestFixture(
            testIdentifier: testIdentifier,
            environment: [
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_ROLE": "recovery-contender",
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_FENCE": lifecycleFence.path,
                "FORGE_FILESYSTEM_LIFECYCLE_TEST_READY": secondReady.path,
            ]
        )
        defer { secondChild.close() }
        try waitForSecureFilesystemLifecycleMarker(
            firstReady,
            child: firstChild,
            timeout: 5
        )
        try waitForSecureFilesystemLifecycleMarker(
            secondReady,
            child: secondChild,
            timeout: 5
        )

        let firstOutcome = String(
            data: try Data(contentsOf: firstReady),
            encoding: .utf8
        )
        let secondOutcome = String(
            data: try Data(contentsOf: secondReady),
            encoding: .utf8
        )
        XCTAssertEqual(
            [firstOutcome, secondOutcome].compactMap { $0 }.sorted(),
            ["blocked", "owner"]
        )

        let owner = firstOutcome == "owner" ? firstChild : secondChild
        let termination = try forceKillSecureFilesystemLifecycleXCTestFixture(
            owner,
            timeout: 2
        )
        XCTAssertEqual(termination.reason, .uncaughtSignal)
        XCTAssertEqual(termination.status, SIGKILL)

        let recoveryService = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let recoveryController = SecureFilesystemServiceController(
            service: recoveryService,
            lifecycleFenceURL: lifecycleFence
        )
        let recovery = Task {
            try await recoveryController.recoverInterruptedUnregister()
        }
        await waitForPendingUnregister(on: recoveryService)
        recoveryService.completeUnregister()
        let recoveryStatus = try await recovery.value
        XCTAssertEqual(recoveryStatus, .notRegistered)
        XCTAssertEqual(recoveryService.events, ["unregister_async"])
        let settledState = await recoveryController.lifecycleState()
        XCTAssertEqual(settledState.phase, .settled)
    }

    @MainActor
    func testInvalidDurableLifecycleFenceBlocksMutationWithoutCallingService() async throws {
        let lifecycleFence = root.appendingPathComponent("invalid-fence.json")
        try OwnerOnlyAtomicFile.write(Data("not-json".utf8), to: lifecycleFence)
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )

        let state = await controller.lifecycleState()
        XCTAssertEqual(state.phase, .stateInvalid)
        do {
            _ = try await controller.register()
            XCTFail("invalid durable state must block registration")
        } catch SecureFilesystemServiceLifecycleError.lifecycleStateInvalid {
            XCTAssertTrue(service.events.isEmpty)
        } catch {
            XCTFail("unexpected invalid-fence error: \(error)")
        }
    }

    @MainActor
    private func waitForPendingUnregister(
        on service: SecureFilesystemServiceRegistrationStub
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if service.hasPendingUnregister { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("service did not enter asynchronous unregister")
    }

    @MainActor
    private func waitForRegistrationStart(
        on service: SecureFilesystemServiceRegistrationStub
    ) async {
        for _ in 0..<1_000 {
            if service.hasStartedRegistration { return }
            await Task.yield()
        }
        XCTFail("service did not enter synchronous registration")
    }

    @MainActor
    private func waitForPendingTimeout(
        on timeout: SecureFilesystemServiceTimeoutSchedulerStub
    ) async {
        for _ in 0..<100 {
            if timeout.hasPendingAction { return }
            await Task.yield()
        }
        XCTFail("service reinstall did not schedule its timeout")
    }

    @MainActor
    private func waitForUncertaintyGate(
        _ gate: SecureFilesystemUncertaintyGate
    ) async {
        for _ in 0..<1_000 {
            if await gate.hasEntered { return }
            await Task.yield()
        }
        XCTFail("uncertainty persistence hook did not start")
    }

    @MainActor
    private func waitForObservedLifecyclePhase(
        _ phase: SecureFilesystemServiceLifecyclePhase,
        context: SecureFilesystemServiceLifecycleObservationContext,
        recorder: SecureFilesystemLifecycleObservationRecorder
    ) async {
        for _ in 0..<1_000 {
            if recorder.phases(for: context).last == phase { return }
            await Task.yield()
        }
        XCTFail("lifecycle observer did not publish \(phase.rawValue)")
    }

    private func seedLifecycleRecord(
        at lifecycleFence: URL,
        intent: String,
        phase: String,
        attemptNumber: Int? = nil
    ) throws {
        var record: [String: Any] = [
            "schemaVersion": attemptNumber == nil ? 1 : 2,
            "operationID": UUID().uuidString.lowercased(),
            "attemptID": UUID().uuidString.lowercased(),
            "intent": intent,
            "phase": phase,
            "createdAtMilliseconds": 1,
            "updatedAtMilliseconds": 1,
        ]
        if let attemptNumber {
            let lockURL = lifecycleFence.appendingPathExtension("lock")
            try OwnerOnlyAtomicFile.write(Data(), to: lockURL)
            var information = stat()
            guard lockURL.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            record["attemptNumber"] = attemptNumber
            record["leaseDevice"] = NSNumber(value: UInt64(information.st_dev))
            record["leaseInode"] = NSNumber(value: UInt64(information.st_ino))
        }
        try OwnerOnlyAtomicFile.write(
            JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
            to: lifecycleFence
        )
    }

    @MainActor
    private func runLifecycleProcessChild(
        role: String,
        lifecycleFence: URL,
        ready: URL
    ) async throws {
        switch role {
        case "unregistering":
            let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
            let controller = SecureFilesystemServiceController(
                service: service,
                lifecycleFenceURL: lifecycleFence
            )
            let operation = Task { try await controller.unregister() }
            await waitForPendingUnregister(on: service)
            try OwnerOnlyAtomicFile.write(Data("ready".utf8), to: ready)
            try await Task.sleep(nanoseconds: 300_000_000_000)
            _ = try await operation.value
        case "registering":
            let service = SecureFilesystemServiceRegistrationStub(
                status: .notRegistered,
                blockRegistration: true
            )
            let controller = SecureFilesystemServiceController(
                service: service,
                lifecycleFenceURL: lifecycleFence
            )
            let operation = Task { try await controller.register() }
            await waitForRegistrationStart(on: service)
            try OwnerOnlyAtomicFile.write(Data("ready".utf8), to: ready)
            try await Task.sleep(nanoseconds: 300_000_000_000)
            service.releaseRegistration()
            _ = try await operation.value
        case "registration-pending":
            let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
            let controller = SecureFilesystemServiceController(
                service: service,
                lifecycleFenceURL: lifecycleFence,
                lifecyclePhaseObserver: { phase in
                    guard phase == .registrationPending else { return }
                    try? OwnerOnlyAtomicFile.write(Data("ready".utf8), to: ready)
                    Thread.sleep(forTimeInterval: 300)
                }
            )
            let operation = Task { try await controller.reinstall() }
            await waitForPendingUnregister(on: service)
            service.completeUnregister()
            try await Task.sleep(nanoseconds: 300_000_000_000)
            _ = try await operation.value
        default:
            throw SecureFilesystemLifecycleProcessError.failed(
                "unknown lifecycle child role \(role)"
            )
        }
    }

    @MainActor
    private func runLifecycleRecoveryContenderChild(
        lifecycleFence: URL,
        ready: URL
    ) async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(
            service: service,
            lifecycleFenceURL: lifecycleFence
        )
        let outcome = SynchronizedString()
        let recovery = Task {
            do {
                _ = try await controller.recoverInterruptedUnregister()
                outcome.set("completed")
            } catch SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired {
                outcome.set("blocked")
            } catch {
                outcome.set("error:\(error.localizedDescription)")
            }
        }
        for _ in 0..<10_000 {
            if service.hasPendingUnregister {
                try OwnerOnlyAtomicFile.write(Data("owner".utf8), to: ready)
                try await Task.sleep(nanoseconds: 300_000_000_000)
                service.completeUnregister()
                await recovery.value
                return
            }
            if let terminal = outcome.value {
                try OwnerOnlyAtomicFile.write(Data(terminal.utf8), to: ready)
                await recovery.value
                return
            }
            await Task.yield()
        }
        throw SecureFilesystemLifecycleProcessError.timeout(
            "recovery contender did not acquire or reject the lease"
        )
    }

    @MainActor
    private func waitForLifecyclePhase(
        _ phase: SecureFilesystemServiceLifecyclePhase,
        on controller: SecureFilesystemServiceController
    ) async -> SecureFilesystemServiceLifecycleState {
        for _ in 0..<1_000 {
            let state = await controller.lifecycleState()
            if state.phase == phase { return state }
            await Task.yield()
        }
        XCTFail("service lifecycle did not reach \(phase.rawValue)")
        return await controller.lifecycleState()
    }

    func testSecureClientCanonicalizesVarAliasBeforeOpeningAuthorizedRoot() throws {
        let aliasedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "secure-filesystem-var-alias-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: aliasedRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: aliasedRoot) }
        let leaf = aliasedRoot.appendingPathComponent("preserved.txt")
        try Data("preserve".utf8).write(to: leaf)
        let transport = SecureFilesystemTransportStub(
            status: .enabled,
            response: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "identity mismatch"
            )
        )
        let client = SecureFilesystemMutationClient(transport: transport)

        let result = try client.deleteLeaf(
            at: leaf,
            context: makeContext(root: aliasedRoot),
            cancellation: ToolCallCancellation(timeoutSeconds: 5),
            recoveryLedger: makeRecoveryLedger(label: "var-alias")
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(
            result.payload["code"] as? String,
            ForgeFilesystemErrorCode.helperIdentityMismatch,
            "\(result.payload)"
        )
        XCTAssertEqual(transport.deleteCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: leaf), Data("preserve".utf8))
    }

    private func makeLeaf(named name: String) throws -> URL {
        let leaf = root.appendingPathComponent(name)
        try Data("preserve".utf8).write(to: leaf)
        return leaf
    }

    private func makeRecoveryLedger(label: String) -> SecureFilesystemRecoveryLedger {
        SecureFilesystemRecoveryLedger(
            root: root.appendingPathComponent(
                "caller-recovery-\(label)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        )
    }

    private struct FilesystemEntrySnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
        let linkCount: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private func filesystemEntrySnapshot(at url: URL) throws -> FilesystemEntrySnapshot {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FilesystemEntrySnapshot(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            owner: UInt32(information.st_uid),
            group: UInt32(information.st_gid),
            linkCount: UInt64(information.st_nlink),
            size: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(information.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private func directoryEntryNames(at directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func delayedFIFOReaderUnblock(at lockURL: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let descriptor = lockURL.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }
    }

    private func makeMutationRequest(
        transactionID: String = UUID().uuidString.lowercased()
    ) -> ForgeFilesystemMutationRequest {
        ForgeFilesystemMutationRequest(
            requestID: UUID().uuidString.lowercased(),
            transactionID: transactionID,
            projectID: UUID().uuidString.lowercased(),
            projectGeneration: 1,
            rootID: "1:2",
            rootIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 2,
                mode: UInt32(S_IFDIR | 0o700),
                owner: UInt32(getuid()),
                group: UInt32(getgid()),
                linkCount: 1
            ),
            relativePathComponents: ["leaf.txt"],
            access: .deleteLeaf,
            contract: .namespaceVersionExact,
            expectedLeafIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 3,
                mode: UInt32(S_IFREG | 0o600),
                owner: UInt32(getuid()),
                group: UInt32(getgid()),
                linkCount: 1
            )
        )
    }

    private func makeMutationRequest(
        rootedAt rootURL: URL,
        transactionID: String = UUID().uuidString.lowercased()
    ) throws -> ForgeFilesystemMutationRequest {
        var information = stat()
        guard Darwin.lstat(rootURL.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return ForgeFilesystemMutationRequest(
            requestID: UUID().uuidString.lowercased(),
            transactionID: transactionID,
            projectID: UUID().uuidString.lowercased(),
            projectGeneration: 1,
            rootID: "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))",
            rootIdentity: ForgeFilesystemIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                mode: UInt32(information.st_mode),
                owner: UInt32(information.st_uid),
                group: UInt32(information.st_gid),
                linkCount: UInt64(information.st_nlink)
            ),
            relativePathComponents: ["leaf.txt"],
            access: .deleteLeaf,
            contract: .currentEntry
        )
    }

    private func quarantineIdentity(at url: URL) throws -> FilesystemQuarantineIdentity {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FilesystemQuarantineIdentity(information)
    }

    private func makeServiceInfo(codeDirectoryHash: String) -> ForgeFilesystemServiceInfo {
        ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        )
    }

    @discardableResult
    private func bindProductionProject(
        app: ForgeApp,
        project: URL,
        clientID: ClientID
    ) throws -> ToolInvocationContext {
        var roots = app.config.model.allowedRoots
        if !roots.contains(project.path) {
            roots.append(project.path)
        }
        _ = try app.config.update(["allowed_roots": roots], save: false)
        let manager = ManagerNode(app: app)
        let registered = try manager.registerProject(
            path: project.path,
            displayName: project.lastPathComponent
        )
        let projectID = ProjectID(try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))
        ))
        let generation = ProjectGeneration(try XCTUnwrap(
            registered["project_generation"] as? UInt64
        ))
        _ = try manager.bindProject(
            projectID: projectID,
            expectedGeneration: generation,
            owner: ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue),
            allowedTools: ["fs_delete", "fs_move"]
        )
        return try app.projectContexts.invocationContext(for: clientID)
    }

    private func makeContext(
        root contextRoot: URL? = nil,
        allowedTools: Set<String> = ["fs_delete", "fs_move"]
    ) -> ToolInvocationContext {
        let effectiveRoot = contextRoot ?? root!
        return ToolInvocationContext(
            projectID: ProjectID(),
            projectGeneration: .initial,
            clientID: ClientID("secure-filesystem-test"),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [effectiveRoot],
                writableRoots: [effectiveRoot],
                allowedTools: allowedTools,
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
    }
}

private enum GenerationResetFixtureError: Error {
    case timeout
}

private final class SynchronizedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class SynchronizedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: String) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private actor SecureFilesystemUncertaintyGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}

@MainActor
private final class SecureFilesystemLifecycleObservationRecorder {
    private var observations: [SecureFilesystemServiceLifecycleObservation] = []

    func record(_ observation: SecureFilesystemServiceLifecycleObservation) {
        observations.append(observation)
    }

    func phases(
        for context: SecureFilesystemServiceLifecycleObservationContext
    ) -> [SecureFilesystemServiceLifecyclePhase] {
        observations.compactMap { observation in
            observation.context == context ? observation.state.phase : nil
        }
    }
}

private final class SecureFilesystemLifecycleXCTestFixture {
    let process: Process
    private let output: SecureFilesystemLifecycleBoundedPipeCapture
    private let error: SecureFilesystemLifecycleBoundedPipeCapture

    init(
        process: Process,
        output: SecureFilesystemLifecycleBoundedPipeCapture,
        error: SecureFilesystemLifecycleBoundedPipeCapture
    ) {
        self.process = process
        self.output = output
        self.error = error
    }

    func diagnostics() -> String {
        guard !process.isRunning else { return "lifecycle child is still running" }
        let standardOutput = output.finishAndSnapshot()
        let standardError = error.finishAndSnapshot()
        return """
        stdout_bytes=\(standardOutput.data.count) \
        stdout_truncated=\(standardOutput.truncated) \
        stdout_drain_timed_out=\(standardOutput.drainTimedOut) \
        stdout_read_error=\(standardOutput.readError ?? "none")
        stderr_bytes=\(standardError.data.count) \
        stderr_truncated=\(standardError.truncated) \
        stderr_drain_timed_out=\(standardError.drainTimedOut) \
        stderr_read_error=\(standardError.readError ?? "none")
        stdout: \(String(decoding: standardOutput.data, as: UTF8.self))
        stderr: \(String(decoding: standardError.data, as: UTF8.self))
        """
    }

    func close() {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        _ = output.finishAndSnapshot()
        _ = error.finishAndSnapshot()
    }

    deinit { close() }
}

private final class SecureFilesystemLifecycleBoundedPipeCapture:
    @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let truncated: Bool
        let drainTimedOut: Bool
        let readError: String?
    }

    let pipe = Pipe()
    private let maximumBytes: Int
    private let stateLock = NSLock()
    private let finalizationLock = NSLock()
    private let drainGroup = DispatchGroup()
    private var retainedData = Data()
    private var truncated = false
    private var drainTimedOut = false
    private var readError: String?
    private var started = false
    private var finalized = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start() {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { drainGroup.leave() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 8_192),
                      !chunk.isEmpty {
                    append(chunk)
                }
            } catch {
                stateLock.lock()
                readError = error.localizedDescription
                stateLock.unlock()
            }
        }
    }

    func closeParentWriteEnd() {
        try? pipe.fileHandleForWriting.close()
    }

    func finishAndSnapshot() -> Snapshot {
        finalizationLock.lock()
        defer { finalizationLock.unlock() }
        if !finalized {
            closeParentWriteEnd()
            if drainGroup.wait(timeout: .now() + 1) == .timedOut {
                stateLock.lock()
                drainTimedOut = true
                stateLock.unlock()
                try? pipe.fileHandleForReading.close()
                _ = drainGroup.wait(timeout: .now() + 1)
            } else {
                try? pipe.fileHandleForReading.close()
            }
            finalized = true
        }
        stateLock.lock()
        let snapshot = Snapshot(
            data: retainedData,
            truncated: truncated,
            drainTimedOut: drainTimedOut,
            readError: readError
        )
        stateLock.unlock()
        return snapshot
    }

    private func append(_ chunk: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let remaining = max(0, maximumBytes - retainedData.count)
        if remaining > 0 {
            retainedData.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining { truncated = true }
    }
}

private enum SecureFilesystemLifecycleProcessError: Error, LocalizedError {
    case failed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail):
            "Lifecycle subprocess failed: \(detail)"
        case .timeout(let detail):
            "Lifecycle subprocess timed out: \(detail)"
        }
    }
}

private func launchSecureFilesystemLifecycleXCTestFixture(
    testIdentifier: String,
    environment additions: [String: String]
) throws -> SecureFilesystemLifecycleXCTestFixture {
    let discovery = try ProcessRunner().run(
        executable: "/usr/bin/xcrun",
        arguments: ["--find", "xctest"],
        timeoutSec: 5,
        maximumOutputBytes: 4_096
    )
    let executablePath = discovery.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard discovery.exitCode == 0,
          !discovery.timedOut,
          !discovery.stdoutTruncated,
          !executablePath.isEmpty,
          FileManager.default.isExecutableFile(atPath: executablePath) else {
        throw SecureFilesystemLifecycleProcessError.failed(
            "xctest discovery failed: \(discovery.stderr)"
        )
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = [
        "-XCTest",
        testIdentifier,
        Bundle(for: SecureFilesystemMutationTests.self).bundleURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    for key in ["XCTestSessionIdentifier", "XCTestConfigurationFilePath"] {
        environment.removeValue(forKey: key)
    }
    for (key, value) in additions { environment[key] = value }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = SecureFilesystemLifecycleBoundedPipeCapture(
        maximumBytes: 64 * 1_024
    )
    let standardError = SecureFilesystemLifecycleBoundedPipeCapture(
        maximumBytes: 64 * 1_024
    )
    process.standardOutput = output.pipe
    process.standardError = standardError.pipe
    output.start()
    standardError.start()
    do {
        try process.run()
    } catch let launchError {
        output.closeParentWriteEnd()
        standardError.closeParentWriteEnd()
        _ = output.finishAndSnapshot()
        _ = standardError.finishAndSnapshot()
        throw launchError
    }
    output.closeParentWriteEnd()
    standardError.closeParentWriteEnd()
    return SecureFilesystemLifecycleXCTestFixture(
        process: process,
        output: output,
        error: standardError
    )
}

private func waitForSecureFilesystemLifecycleMarker(
    _ markerURL: URL,
    child: SecureFilesystemLifecycleXCTestFixture,
    timeout: TimeInterval
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: markerURL.path) { return }
        guard child.process.isRunning else {
            throw SecureFilesystemLifecycleProcessError.failed(child.diagnostics())
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw SecureFilesystemLifecycleProcessError.timeout(
        child.process.isRunning ? "ready marker was not written" : child.diagnostics()
    )
}

private func waitForSecureFilesystemLifecycleXCTestFixtureExit(
    _ child: SecureFilesystemLifecycleXCTestFixture,
    timeout: TimeInterval
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while child.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard !child.process.isRunning else {
        throw SecureFilesystemLifecycleProcessError.timeout(
            "lifecycle child did not exit; \(child.diagnostics())"
        )
    }
    guard child.process.terminationReason == .exit,
          child.process.terminationStatus == 0 else {
        throw SecureFilesystemLifecycleProcessError.failed(child.diagnostics())
    }
}

private func forceKillSecureFilesystemLifecycleXCTestFixture(
    _ child: SecureFilesystemLifecycleXCTestFixture,
    timeout: TimeInterval
) throws -> (reason: Process.TerminationReason, status: Int32) {
    guard child.process.isRunning else {
        throw SecureFilesystemLifecycleProcessError.failed(
            "child exited before SIGKILL; \(child.diagnostics())"
        )
    }
    guard Darwin.kill(child.process.processIdentifier, SIGKILL) == 0 else {
        throw SecureFilesystemLifecycleProcessError.failed(
            "SIGKILL failed with errno \(errno)"
        )
    }
    let deadline = Date().addingTimeInterval(timeout)
    while child.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard !child.process.isRunning else {
        throw SecureFilesystemLifecycleProcessError.timeout(
            "child did not confirm termination after SIGKILL"
        )
    }
    return (child.process.terminationReason, child.process.terminationStatus)
}

private final class SecureFilesystemServiceRegistrationStub:
    SecureFilesystemServiceRegistering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let registrationReleaseGate = DispatchSemaphore(value: 0)
    private var storedStatus: SMAppService.Status
    private var storedEvents: [String] = []
    private var pendingUnregisters: [(@Sendable (Error?) -> Void)] = []
    private var registrationStarted = false
    private var registrationOnMainThread: Bool?
    private let blockRegistration: Bool

    var status: SMAppService.Status {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedStatus
        }
        set {
            lock.lock()
            storedStatus = newValue
            lock.unlock()
        }
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var hasPendingUnregister: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pendingUnregisters.isEmpty
    }

    var pendingUnregisterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingUnregisters.count
    }

    var hasStartedRegistration: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registrationStarted
    }

    var registrationWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return registrationOnMainThread
    }

    init(status: SMAppService.Status, blockRegistration: Bool = false) {
        storedStatus = status
        self.blockRegistration = blockRegistration
    }

    func register() throws {
        lock.lock()
        registrationStarted = true
        registrationOnMainThread = Thread.isMainThread
        lock.unlock()
        if blockRegistration {
            registrationReleaseGate.wait()
        }
        lock.lock()
        storedEvents.append("register")
        storedStatus = .enabled
        lock.unlock()
    }

    func unregister() throws {
        lock.lock()
        storedEvents.append("unregister")
        storedStatus = .notRegistered
        lock.unlock()
    }

    func unregister(completionHandler: @Sendable @escaping (Error?) -> Void) {
        lock.lock()
        storedEvents.append("unregister_async")
        pendingUnregisters.append(completionHandler)
        lock.unlock()
    }

    func completeUnregister(error: Error? = nil) {
        lock.lock()
        if error == nil { storedStatus = .notRegistered }
        let completion = pendingUnregisters.isEmpty
            ? nil
            : pendingUnregisters.removeFirst()
        lock.unlock()
        completion?(error)
    }

    func releaseRegistration() {
        registrationReleaseGate.signal()
    }
}

private final class SecureFilesystemServiceTimeoutSchedulerStub:
    SecureFilesystemServiceTimeoutScheduling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    var hasPendingAction: Bool {
        lock.lock()
        defer { lock.unlock() }
        return action != nil
    }

    func schedule(
        after _: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        lock.lock()
        self.action = action
        lock.unlock()
        return { [weak self] in self?.cancel() }
    }

    func fire() {
        let actionToRun: (@Sendable () -> Void)?
        lock.lock()
        actionToRun = action
        action = nil
        lock.unlock()
        actionToRun?()
    }

    private func cancel() {
        lock.lock()
        action = nil
        lock.unlock()
    }
}

private struct SecureFilesystemServicePackageInspectorStub:
    SecureFilesystemServicePackageInspecting {
    let observation: SecureFilesystemServicePackageObservation

    func inspect() -> SecureFilesystemServicePackageObservation { observation }
}

private final class BlockingSecureFilesystemServicePackageInspector:
    SecureFilesystemServicePackageInspecting,
    @unchecked Sendable {
    private let observation: SecureFilesystemServicePackageObservation
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var storedCallCount = 0
    private var shouldBlock = true

    init(observation: SecureFilesystemServicePackageObservation) {
        self.observation = observation
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func inspect() -> SecureFilesystemServicePackageObservation {
        lock.lock()
        storedCallCount += 1
        let block = shouldBlock
        lock.unlock()
        if block {
            _ = releaseGate.wait(timeout: .now() + 2)
            lock.lock()
            shouldBlock = false
            lock.unlock()
        }
        return observation
    }

    func release() {
        releaseGate.signal()
    }
}

private final class SecureFilesystemTransportStub: SecureFilesystemServiceTransport,
    @unchecked Sendable
{
    private let status: SecureFilesystemServiceStatus
    private let operationalProbeValue: SecureFilesystemServiceOperationalProbe?
    private let response: ForgeFilesystemResponse
    private let transactionStatus: ForgeFilesystemTransactionStatus
    private let deleteResponseProvider: ((ForgeFilesystemMutationRequest) -> ForgeFilesystemResponse)?
    private let transactionStatusProvider:
        ((ForgeFilesystemTransactionControlRequest) -> ForgeFilesystemTransactionStatus)?
    private let acknowledgeResponseProvider:
        ((ForgeFilesystemTransactionControlRequest) -> ForgeFilesystemResponse)?
    private let lock = NSLock()
    private var storedDeleteCallCount = 0
    private var storedQueryCallCount = 0
    private var storedResumeCallCount = 0
    private var storedAcknowledgeCallCount = 0

    init(
        status: SecureFilesystemServiceStatus,
        operationalProbe: SecureFilesystemServiceOperationalProbe? = nil,
        response: ForgeFilesystemResponse = ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "unavailable"
        ),
        transactionStatus: ForgeFilesystemTransactionStatus = ForgeFilesystemTransactionStatus(
            transactionID: nil,
            disposition: .unavailable,
            code: ForgeFilesystemErrorCode.transactionUnavailable,
            message: "unavailable",
            terminal: false,
            committed: false,
            durabilityConfirmed: false,
            recoveryRequired: false,
            acknowledgementRequired: false
        ),
        deleteResponseProvider: ((ForgeFilesystemMutationRequest) -> ForgeFilesystemResponse)? = nil,
        transactionStatusProvider:
            ((ForgeFilesystemTransactionControlRequest) -> ForgeFilesystemTransactionStatus)? = nil,
        acknowledgeResponseProvider:
            ((ForgeFilesystemTransactionControlRequest) -> ForgeFilesystemResponse)? = nil
    ) {
        self.status = status
        operationalProbeValue = operationalProbe
        self.response = response
        self.transactionStatus = transactionStatus
        self.deleteResponseProvider = deleteResponseProvider
        self.transactionStatusProvider = transactionStatusProvider
        self.acknowledgeResponseProvider = acknowledgeResponseProvider
    }

    var deleteCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteCallCount
    }

    var queryCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedQueryCallCount
    }

    var resumeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedResumeCallCount
    }

    var acknowledgeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAcknowledgeCallCount
    }

    func serviceStatus() -> SecureFilesystemServiceStatus {
        status
    }

    func operationalProbe(timeout _: TimeInterval) -> SecureFilesystemServiceOperationalProbe {
        operationalProbeValue ?? SecureFilesystemServiceOperationalProbe(
            operational: status == .enabled,
            code: status == .enabled
                ? "ok"
                : ForgeFilesystemErrorCode.helperUnavailable,
            message: status == .enabled ? "available" : "unavailable"
        )
    }

    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        lock.lock()
        storedDeleteCallCount += 1
        lock.unlock()
        return deleteResponseProvider?(request) ?? response
    }

    func queryTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemTransactionStatus {
        lock.lock()
        storedQueryCallCount += 1
        lock.unlock()
        return transactionStatusProvider?(request) ?? transactionStatus
    }

    func resumeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        lock.lock()
        storedResumeCallCount += 1
        lock.unlock()
        return response
    }

    func acknowledgeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        lock.lock()
        storedAcknowledgeCallCount += 1
        lock.unlock()
        return acknowledgeResponseProvider?(request) ?? response
    }
}

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
            ForgeFilesystemErrorCode.transactionUnavailable
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
        }
    }

    @MainActor
    func testConcurrentDisableSupersedesPendingServiceReinstall() async throws {
        let service = SecureFilesystemServiceRegistrationStub(status: .enabled)
        let controller = SecureFilesystemServiceController(service: service)
        let replacement = Task { try await controller.reinstall() }
        await waitForPendingUnregister(on: service)

        XCTAssertEqual(try controller.unregister(), .notRegistered)
        service.completeUnregister()
        do {
            _ = try await replacement.value
            XCTFail("a newer disable action must supersede replacement registration")
        } catch is SecureFilesystemServiceLifecycleError {
            XCTAssertEqual(service.events, ["unregister_async", "unregister"])
        } catch {
            XCTFail("unexpected lifecycle error: \(error)")
        }
    }

    @MainActor
    private func waitForPendingUnregister(
        on service: SecureFilesystemServiceRegistrationStub
    ) async {
        for _ in 0..<100 {
            if service.hasPendingUnregister { return }
            await Task.yield()
        }
        XCTFail("service did not enter asynchronous unregister")
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

    private func makeServiceInfo(codeDirectoryHash: String) -> ForgeFilesystemServiceInfo {
        ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        )
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

private final class SecureFilesystemServiceRegistrationStub:
    SecureFilesystemServiceRegistering
{
    var status: SMAppService.Status
    private(set) var events: [String] = []
    private var pendingUnregister: (@Sendable (Error?) -> Void)?

    var hasPendingUnregister: Bool { pendingUnregister != nil }

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        events.append("register")
        status = .enabled
    }

    func unregister() throws {
        events.append("unregister")
        status = .notRegistered
    }

    func unregister(completionHandler: @Sendable @escaping (Error?) -> Void) {
        events.append("unregister_async")
        pendingUnregister = completionHandler
    }

    func completeUnregister(error: Error? = nil) {
        if error == nil { status = .notRegistered }
        let completion = pendingUnregister
        pendingUnregister = nil
        completion?(error)
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
    private let response: ForgeFilesystemResponse
    private let transactionStatus: ForgeFilesystemTransactionStatus
    private let deleteResponseProvider: ((ForgeFilesystemMutationRequest) -> ForgeFilesystemResponse)?
    private let lock = NSLock()
    private var storedDeleteCallCount = 0
    private var storedQueryCallCount = 0
    private var storedResumeCallCount = 0
    private var storedAcknowledgeCallCount = 0

    init(
        status: SecureFilesystemServiceStatus,
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
        deleteResponseProvider: ((ForgeFilesystemMutationRequest) -> ForgeFilesystemResponse)? = nil
    ) {
        self.status = status
        self.response = response
        self.transactionStatus = transactionStatus
        self.deleteResponseProvider = deleteResponseProvider
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
        return transactionStatus
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
        return response
    }
}

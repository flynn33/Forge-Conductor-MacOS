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
                cancellation: ToolCallCancellation(timeoutSeconds: 5)
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
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
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
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
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
            cancellation: ToolCallCancellation(timeoutSeconds: 5)
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

    private func makeMutationRequest() -> ForgeFilesystemMutationRequest {
        ForgeFilesystemMutationRequest(
            requestID: UUID().uuidString.lowercased(),
            transactionID: UUID().uuidString.lowercased(),
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

    private func makeContext(root contextRoot: URL? = nil) -> ToolInvocationContext {
        let effectiveRoot = contextRoot ?? root!
        return ToolInvocationContext(
            projectID: ProjectID(),
            projectGeneration: .initial,
            clientID: ClientID("secure-filesystem-test"),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [effectiveRoot],
                writableRoots: [effectiveRoot],
                allowedTools: ["fs_delete", "fs_move"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
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

private final class SecureFilesystemTransportStub: SecureFilesystemServiceTransport,
    @unchecked Sendable
{
    private let status: SecureFilesystemServiceStatus
    private let response: ForgeFilesystemResponse
    private let lock = NSLock()
    private var storedDeleteCallCount = 0

    init(
        status: SecureFilesystemServiceStatus,
        response: ForgeFilesystemResponse = ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "unavailable"
        )
    ) {
        self.status = status
        self.response = response
    }

    var deleteCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteCallCount
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
        return response
    }
}

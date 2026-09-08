import XCTest
@testable import ForgeConductorCore

final class MCPTaskHTTPTests: XCTestCase, @unchecked Sendable {
    func testSharedAdmissionBoundsNamespacesCancellationAndExactRelease() throws {
        let admission = MCPRequestAdmission(maximumActiveRequests: 2)
        let one = UUID(), two = UUID()
        let first = MCPRequestAdmission.Key(sessionID: one, id: .string("1"))
        let peer = MCPRequestAdmission.Key(sessionID: two, id: .string("1"))
        let a = ToolCallCancellation(timeoutSeconds: 5), b = ToolCallCancellation(timeoutSeconds: 5)
        guard case .accepted = admission.reserve(first, cancellation: a),
              case .accepted = admission.reserve(peer, cancellation: b),
              case .duplicate = admission.reserve(first, cancellation: b),
              case .capacityExceeded = admission.reserve(.init(sessionID: one, id: .number("2")), cancellation: b) else {
            return XCTFail("Admission did not preserve shared capacity and session namespaces")
        }
        admission.cancel(first)
        XCTAssertThrowsError(try a.checkCancellation())
        XCTAssertNoThrow(try b.checkCancellation())
        admission.finish(first, cancellation: b)
        XCTAssertEqual(admission.activeCount, 2, "Foreign completion cannot free a live slot")
        admission.finish(first, cancellation: a)
        admission.setOpen(false)
        XCTAssertEqual(admission.activeCount, 1, "Closing must retain unfinished work")
        XCTAssertThrowsError(try b.checkCancellation())
        guard case .closed = admission.reserve(first, cancellation: a) else { return XCTFail("Closed admission reopened") }
        admission.finish(peer, cancellation: b)
        XCTAssertEqual(admission.activeCount, 0)
        XCTAssertNotEqual(MCPRequestAdmission.Identifier.string("1").sha256,
                          MCPRequestAdmission.Identifier.number("1").sha256)
        XCTAssertNil(MCPRequestAdmission.Identifier(NSNumber(value: true), strict: true))
        XCTAssertNil(MCPRequestAdmission.Identifier(String(repeating: "x", count: 257), strict: true))
        XCTAssertNil(MCPRequestAdmission.Identifier(NSNumber(value: UInt64.max), strict: true))
    }

    func testNativeAndProtocolChannelsShareEightSlotsWithoutCancellationAliasing() throws {
        let admission = MCPRequestAdmission(maximumActiveRequests: 8)
        let identity = UUID()
        let keys: [MCPRequestAdmission.Key] = (0..<4).map { .init(sessionID: identity, id: .number(String($0))) }
            + (0..<4).map { .nativeProviderCall(conversationID: identity, referenceSHA256: String(repeating: String($0), count: 64)) }
        let tokens = keys.map { _ in ToolCallCancellation(timeoutSeconds: 5) }
        for (key, token) in zip(keys, tokens) {
            guard case .accepted = admission.reserve(key, cancellation: token) else { return XCTFail("Shared slot refused") }
        }
        XCTAssertEqual(admission.activeCount, 8)
        XCTAssertEqual(admission.activeCount(sessionID: identity), 4)
        let waiter = ToolCallCancellation(timeoutSeconds: 5)
        guard case .duplicate = admission.reserve(keys[4], cancellation: waiter),
              case .capacityExceeded = admission.reserve(.nativeProviderCatalog(conversationID: identity, requestID: UUID()), cancellation: waiter) else {
            return XCTFail("Native work escaped the shared capacity or duplicate owner")
        }
        waiter.cancel()
        admission.finish(keys[4], cancellation: waiter)
        XCTAssertEqual(admission.activeCount, 8)
        admission.cancel(sessionID: identity)
        for token in tokens.prefix(4) { XCTAssertThrowsError(try token.checkCancellation()) }
        for token in tokens.suffix(4) { XCTAssertNoThrow(try token.checkCancellation()) }
        XCTAssertEqual(admission.activeCount, 8, "Cancellation retains work until its actual owner exits")
        admission.setOpen(false)
        for token in tokens { XCTAssertThrowsError(try token.checkCancellation()) }
        for (key, token) in zip(keys, tokens) { admission.finish(key, cancellation: token) }
        XCTAssertEqual(admission.activeCount, 0)
    }

    func testRealLoopbackInitializationClosedProfileAndAuthenticatedMethods() async throws {
        let fixture = try MCPHTTPFixture()
        defer { fixture.stop() }
        let unauthenticated = try fixture.fetch(method: "GET", useDefaultCredential: false)
        XCTAssertEqual(unauthenticated.1.statusCode, 401)
        XCTAssertEqual(try fixture.fetch(method: "GET").1.statusCode, 405)
        XCTAssertEqual(try fixture.fetch(method: "DELETE").1.statusCode, 405)
        XCTAssertEqual(try fixture.fetch(method: "GET", origin: "https://untrusted.example").1.statusCode, 403)
        let badVersion = try fixture.rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2026-07-28"]])
        XCTAssertEqual(badVersion.1.statusCode, 400)
        let session = try fixture.initialize()
        XCTAssertEqual(try fixture.rpc(Self.list(id: 2), session: session).1.statusCode, 400)
        let initialized = try fixture.rpc(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session)
        XCTAssertEqual(initialized.1.statusCode, 202)
        XCTAssertTrue(initialized.0.isEmpty)
        let list = try fixture.rpc(Self.list(id: 3), session: session)
        XCTAssertEqual(list.1.statusCode, 200)
        let object = try JSONSupport.object(from: list.0)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), MCPNativeTaskSourceProfile.toolNames)
        let rejected = try fixture.rpc(Self.call("shell_exec", id: 4), session: session)
        XCTAssertTrue(String(decoding: rejected.0, as: UTF8.self).contains("tool_not_allowed"))
        XCTAssertEqual(fixture.dispatcher.calls, 0)
        XCTAssertEqual(try fixture.rpc(Self.list(id: 5), session: session,
            credential: fixture.peerCredential).1.statusCode, 404)
        XCTAssertEqual(try fixture.rpc(Self.list(id: 6), session: session, version: "2025-06-18").1.statusCode, 400)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testStoppedSourceRequestsAndListenerRebindCannotReuseSessions() async throws {
        let fixture = try MCPHTTPFixture()
        defer { fixture.stop() }
        let session = try fixture.initializeReady()
        fixture.service.setOperational(false)
        let stopped = try fixture.rpc(Self.call("fs_read", id: "read"), session: session)
        XCTAssertTrue(String(decoding: stopped.0, as: UTF8.self).contains("service_stopped"))
        XCTAssertEqual(fixture.dispatcher.calls, 0)
        let status = try fixture.rpc(Self.call("clu_status", id: "status"), session: session)
        XCTAssertEqual(status.1.statusCode, 200)
        XCTAssertEqual(fixture.dispatcher.calls, 1)
        fixture.server.stop()
        try fixture.server.start()
        XCTAssertEqual(try fixture.rpc(Self.list(id: 3), session: session).1.statusCode, 404)
        let reinitialized = try fixture.initializeReady()
        XCTAssertNotEqual(reinitialized, session)
        XCTAssertEqual(try fixture.rpc(Self.list(id: 4), session: reinitialized).1.statusCode, 200)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testProtocolSessionCapacityAndIdleExpiryRemainBounded() async throws {
        let clock = FixedClock(Date())
        let fixture = try MCPHTTPFixture(clock: clock)
        defer { fixture.stop() }
        var sessions: [String] = []
        for _ in 0..<32 { sessions.append(try fixture.initializeReady()) }
        let overflow = try fixture.rpc(["jsonrpc": "2.0", "id": "overflow", "method": "initialize",
            "params": ["protocolVersion": MCPTaskHTTPService.protocolVersion]])
        XCTAssertEqual(overflow.1.statusCode, 503)
        clock.date = clock.date.addingTimeInterval(601)
        XCTAssertEqual(try fixture.rpc(Self.list(id: "expired"), session: sessions[0]).1.statusCode, 404)
        let replacement = try fixture.initializeReady()
        XCTAssertFalse(sessions.contains(replacement))
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testSourceNamespaceHeaderIsRequiredAndNeverReplacesAuthentication() async throws {
        let fixture = try MCPHTTPFixture()
        defer { fixture.stop() }
        fixture.service.setOperational(true)
        let session = try fixture.initializeReady()
        var request = try fixture.request(Self.call("fs_read", id: "missing-source-namespace"),
            session: session, includeSourceSession: false)
        let missing = try HTTPTestHelpers.fetch(request)
        XCTAssertTrue(String(decoding: missing.0, as: UTF8.self).contains("source_session_id_required"))
        request.setValue("invalid-namespace", forHTTPHeaderField: "Forge-Source-Session-ID")
        let invalid = try HTTPTestHelpers.fetch(request)
        XCTAssertTrue(String(decoding: invalid.0, as: UTF8.self).contains("source_session_id_required"))
        request.setValue(fixture.sourceSessionID.uuidString.lowercased(), forHTTPHeaderField: "Forge-Source-Session-ID")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        XCTAssertEqual(try HTTPTestHelpers.fetch(request).1.statusCode, 401)
        XCTAssertEqual(fixture.dispatcher.calls, 0)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testCancellationHasItsOwnAuthenticationCapacityAndCannotCancelPeerSession() async throws {
        let fixture = try MCPHTTPFixture(blockReads: true)
        defer { fixture.stop() }
        let first = try fixture.initializeReady()
        let second = try fixture.initializeReady()
        fixture.service.setOperational(true)
        var pending: [URLSessionDataTask] = []
        let completions = (0..<8).map { expectation(description: "request \($0) exits") }
        for index in 0..<8 {
            let session = index == 0 ? first : second
            let id = index < 2 ? "same" : "read-\(index)"
            let request = try fixture.request(Self.call("fs_read", id: id), session: session)
            let task = fixture.networkSession.dataTask(with: request) { _, _, _ in completions[index].fulfill() }
            pending.append(task); task.resume()
        }
        defer { pending.forEach { $0.cancel() } }
        let entered = await fixture.dispatcher.waitForCalls(8)
        XCTAssertTrue(entered)
        XCTAssertEqual(fixture.service.retainedWorkCount, 8)
        XCTAssertEqual(try fixture.rpc(Self.list(id: "extra"), session: first).1.statusCode, 503)
        let cancellation = try fixture.rpc(["jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": "same"]], session: first)
        XCTAssertEqual(cancellation.1.statusCode, 202)
        let cancelled = await fixture.dispatcher.waitForCancelled(1)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(fixture.dispatcher.cancelledSessionIDs, [try XCTUnwrap(UUID(uuidString: first))])
        let shutdown = await fixture.service.shutdown()
        XCTAssertTrue(shutdown)
        await fulfillment(of: completions, timeout: 5)
        XCTAssertEqual(fixture.service.retainedWorkCount, 0)
    }

    private static func list(id: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "method": "tools/list"] }
    private static func call(_ name: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": [:]]]
    }
}

private final class MCPHTTPFixture {
    let home: URL
    let app: ForgeApp
    let server: DashboardServer
    let service: MCPTaskHTTPService
    let dispatcher: MCPHTTPFixtureDispatcher
    let credential: NativeTaskCapabilityCredential
    let peerCredential: NativeTaskCapabilityCredential
    let url: URL
    let networkSession: URLSession
    let sourceSessionID = UUID()

    init(blockReads: Bool = false, clock: any Clock = SystemClock()) throws {
        let networkConfig = URLSessionConfiguration.ephemeral
        networkConfig.httpMaximumConnectionsPerHost = 16
        networkSession = URLSession(configuration: networkConfig)
        home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-task-http-\(UUID().uuidString)")
        app = try ForgeApp.bootstrap(home: home)
        credential = try .init(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 17, count: 32))
        peerCredential = try .init(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 29, count: 32))
        dispatcher = MCPHTTPFixtureDispatcher(binding: credential.verifier.sha256, blockReads: blockReads)
        let primary = dispatcher, expected = credential.verifier, peer = peerCredential.verifier
        service = MCPTaskHTTPService(clock: clock) { credential, cancellation in
            try cancellation.checkCancellation()
            if credential.verifier == expected { return primary }
            if credential.verifier == peer { return MCPHTTPFixtureDispatcher(binding: peer.sha256, blockReads: false) }
            throw NativeTaskCapabilityError.credentialRejected
        }
        let port = UInt16.random(in: 29_000...39_000)
        server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        server.taskHTTPService = service
        url = URL(string: "http://127.0.0.1:\(port)/mcp/continuity")!
        try server.start()
    }

    func stop() { networkSession.invalidateAndCancel(); server.stop(); app.shutdown(); try? FileManager.default.removeItem(at: home) }
    func fetch(method: String, credential: NativeTaskCapabilityCredential? = nil,
               origin: String? = nil, useDefaultCredential: Bool = true) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method
        if let value = credential ?? (useDefaultCredential ? self.credential : nil) {
            request.setValue("Bearer " + value.authorizationValue, forHTTPHeaderField: "Authorization")
        }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return try HTTPTestHelpers.fetch(request)
    }

    func request(_ object: [String: Any], session: String? = nil,
                 credential: NativeTaskCapabilityCredential? = nil, version: String = MCPTaskHTTPService.protocolVersion,
                 includeSourceSession: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if includeSourceSession { request.setValue(sourceSessionID.uuidString.lowercased(), forHTTPHeaderField: "Forge-Source-Session-ID") }
        request.setValue("Bearer " + (credential ?? self.credential).authorizationValue, forHTTPHeaderField: "Authorization")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSupport.data(from: object)
        return request
    }
    func rpc(_ object: [String: Any], session: String? = nil,
             credential: NativeTaskCapabilityCredential? = nil, version: String = MCPTaskHTTPService.protocolVersion) throws -> (Data, HTTPURLResponse) {
        try HTTPTestHelpers.fetch(request(object, session: session, credential: credential, version: version))
    }
    func initialize() throws -> String {
        let response = try rpc(["jsonrpc": "2.0", "id": UUID().uuidString, "method": "initialize",
            "params": ["protocolVersion": MCPTaskHTTPService.protocolVersion]])
        XCTAssertEqual(response.1.statusCode, 200)
        return try XCTUnwrap(response.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }
    func initializeReady() throws -> String {
        let session = try initialize()
        XCTAssertEqual(try rpc(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session).1.statusCode, 202)
        return session
    }
}

private final class MCPHTTPFixtureDispatcher: MCPTaskHTTPDispatching, @unchecked Sendable {
    let sessionBindingSHA256: String
    let expiresAt = Date().addingTimeInterval(3600)
    private let blockReads: Bool
    private let lock = NSLock()
    private var callCount = 0
    private var cancelled: Set<UUID> = []
    init(binding: String, blockReads: Bool) { sessionBindingSHA256 = binding; self.blockReads = blockReads }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    var cancelledSessionIDs: Set<UUID> { lock.lock(); defer { lock.unlock() }; return cancelled }
    func toolDescriptorsJSON() throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: MCPNativeTaskSourceProfile.toolNames.sorted().map {
            ["name": $0, "inputSchema": ["type": "object"]] as [String: Any]
        })
    }
    private func recordCall() { lock.lock(); callCount += 1; lock.unlock() }
    private func recordCancellation(_ id: UUID) { lock.lock(); cancelled.insert(id); lock.unlock() }
    func call(name: String, argumentsJSON: Data, identity: MCPTaskRequestIdentity,
              cancellation: ToolCallCancellation) async throws -> ToolResult {
        recordCall()
        if blockReads && name == "fs_read" {
            do {
                while true { try cancellation.checkCancellation(); try await Task.sleep(nanoseconds: 5_000_000) }
            } catch { recordCancellation(identity.sessionID); throw error }
        }
        return .success(["ok": true, "observed_tool": name])
    }
    func waitForCalls(_ expected: Int) async -> Bool {
        for _ in 0..<1_000 {
            if calls == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
    func waitForCancelled(_ expected: Int) async -> Bool {
        for _ in 0..<1_000 {
            if cancelledSessionIDs.count == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

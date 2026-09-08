import XCTest
@testable import ForgeConductorCore

final class MCPNativeTaskSourceTests: XCTestCase, @unchecked Sendable {
    func testDuplicateAcrossProtocolSessionsCannotTakePendingReadOwnership() async throws {
        let managerInstanceID = UUID()
        let fixture = try await NativeSourceHTTPFixture.create(sourceManagerInstanceID: managerInstanceID)
        defer { fixture.stop() }
        let session = try fixture.initializeReady(credential: fixture.credential)
        let retrySession = try fixture.initializeReady(credential: fixture.credential)
        XCTAssertNotEqual(session, retrySession)
        let repository = fixture.app.projectContexts.repository
        let attachment = try await repository.authenticateNativeTaskCapability(credential: fixture.credential)
        let arguments: [String: Any] = ["path": fixture.file.path]
        let domain = "forge.continuity.source-session.v1\0" + fixture.credential.capabilityID.uuidString.lowercased()
            + "\0" + fixture.sourceSessionID.uuidString.lowercased()
        let hash = String(JSONSupport.sha256Hex(Data(domain.utf8)).prefix(32))
        let namespace = try XCTUnwrap(UUID(uuidString:
            "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20))"))
        let request = try NativeSourceReadRequest(key: .init(sessionID: namespace,
            requestIDSHA256: MCPRequestAdmission.Identifier.string("overlapping-read").sha256),
            toolName: "fs_read", canonicalArgumentsJSON: ForgeJSONCanonicalizationV1.data(from: arguments),
            managerInstanceID: managerInstanceID)
        let policy = try fixture.app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: fixture.projectID.description, projectGeneration: 1))
        // Hold the original worker at its actual durable admission boundary.
        // The retry reaches the production dispatcher over another live session
        // with the same manager, capability, durable namespace and typed RPC ID.
        let decision = try await repository.admitContinuitySourceRead(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: policy)
        guard case .execute(let original) = decision else { return XCTFail("Original read did not acquire admission") }
        XCTAssertEqual(original.chargedCalls, 1)
        let retry = try fixture.call("fs_read", id: "overlapping-read", arguments: arguments, session: retrySession)
        XCTAssertEqual(retry["code"] as? String, "source_request_in_progress")
        XCTAssertNil(retry["content"], "A duplicate request must not execute or disclose the original reservation")

        let cancellation = ToolCallCancellation(timeoutSeconds: 30)
        let authorization = try ToolAuthorizationService(paths: fixture.app.paths, config: fixture.app.config)
            .authorize(tool: "fs_read", arguments: arguments, context: attachment.context,
                clientID: attachment.context.clientID, binding: nil, cancellation: cancellation)
        guard case .allowed(let normalized) = authorization else { return XCTFail("Approved fixture read was denied") }
        try await repository.beginContinuitySourceRead(admission: original, policySelection: policy, cancellation: cancellation)
        let result = try XCTUnwrap(FilesystemToolPack().handle(name: "fs_read", arguments: normalized,
            context: attachment.context, clientID: attachment.context.clientID, app: fixture.app, cancellation: cancellation))
        XCTAssertTrue(result.ok)
        let fullResult = try ForgeJSONCanonicalizationV1.data(from: ["ok": result.ok, "is_error": result.isError, "payload": result.payload])
        let receipt = try await repository.completeContinuitySourceRead(admission: original,
            canonicalToolResultJSON: fullResult, policySelection: policy, cancellation: cancellation)
        XCTAssertEqual(receipt.chargedCalls, 1)
        XCTAssertEqual(receipt.reservationID, original.reservationID)
        try Data("A replay must not read this replacement".utf8).write(to: fixture.file)
        let replay = try fixture.call("fs_read", id: "overlapping-read", arguments: arguments, session: session)
        XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: replay),
            try ForgeJSONCanonicalizationV1.data(from: result.payload))
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testActualCapabilityPackReadReplayCheckpointAndHandoffAcrossLoopback() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let session = try fixture.initializeReady(credential: fixture.credential)
        let peer = try fixture.initializeReady(credential: fixture.peerCredential)
        let listed = try fixture.rpc(["jsonrpc": "2.0", "id": "list", "method": "tools/list"], session: session)
        let tools = try XCTUnwrap((try JSONSupport.object(from: listed.0)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), MCPNativeTaskSourceProfile.toolNames)

        let arguments: [String: Any] = ["path": fixture.file.path]
        let first = try fixture.call("fs_read", id: "original-read", arguments: arguments, session: session)
        XCTAssertEqual(first["content"] as? String, "native source marker one")
        try Data("native source marker two".utf8).write(to: fixture.file)
        let repeated = try fixture.call("fs_read", id: "original-read", arguments: arguments, session: session)
        XCTAssertEqual(try JSONSupport.data(from: repeated), try JSONSupport.data(from: first), "A completed request must not redispatch")
        let independent = try fixture.call("fs_read", id: "original-read", arguments: arguments, session: peer,
            credential: fixture.peerCredential)
        XCTAssertEqual(independent["content"] as? String, "native source marker two")
        let changedArguments = try fixture.call("fs_read", id: "original-read", arguments: ["path": fixture.outside.path], session: session)
        XCTAssertEqual(changedArguments["code"] as? String, "source_request_conflict")
        let denied = try fixture.call("fs_read", id: "outside", arguments: ["path": fixture.outside.path], session: session)
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: denied), as: UTF8.self).contains("private outside marker"))

        let checkpoint = try fixture.call("session_checkpoint", id: "checkpoint", arguments: ["goal": "Actual native source progress"], session: session)
        XCTAssertEqual(checkpoint["ok"] as? Bool, true, "\(checkpoint)")
        let replay = try fixture.call("session_checkpoint", id: "checkpoint", arguments: ["goal": "Actual native source progress"], session: session)
        XCTAssertEqual(try JSONSupport.data(from: checkpoint), try JSONSupport.data(from: replay))
        let continuityID = try XCTUnwrap(checkpoint["continuity_id"] as? String)
        let ordinaryRestore = try fixture.rpc(["jsonrpc": "2.0", "id": "source-context-get", "method": "tools/call",
            "params": ["name": "context_get", "arguments": ["handoff_id": continuityID]]], session: session)
        XCTAssertEqual(ordinaryRestore.1.statusCode, 200)
        let restoreObject = try JSONSupport.object(from: ordinaryRestore.0)
        XCTAssertEqual((restoreObject["error"] as? [String: Any])?["message"] as? String, "tool_not_allowed")
        XCTAssertNil(restoreObject["result"], "An attached source profile has no provisional successor retrieval authority")
        let handoff = try fixture.call("session_handoff", id: "handoff", arguments: ["handoff_id": continuityID], session: session)
        XCTAssertEqual(handoff["ok"] as? Bool, true, "\(handoff)")
        XCTAssertEqual(handoff["continuity_id"] as? String, continuityID)
        let started = try fixture.call("clu_start_handoff", id: "explicit-start",
            arguments: ["continuity_id": continuityID, "idempotency_key": "native-http-explicit"], session: session)
        XCTAssertEqual(started["ok"] as? Bool, true, "\(started)")
        XCTAssertNotNil(started["operation_id"] as? String)
        XCTAssertFalse(try fixture.app.config.budgetPolicySelection(scope: .globalDefault).policy.automaticHandoffEnabled)
        let fenced = try fixture.call("fs_read", id: "read-after-handoff", arguments: arguments, session: session)
        XCTAssertEqual(fenced["code"] as? String, "source_fenced")
        let cachedFenced = try fixture.call("fs_read", id: "original-read", arguments: arguments, session: session)
        XCTAssertEqual(cachedFenced["code"] as? String, "source_fenced", "Cached content must cross the new source fence")
        let samePeer = try fixture.call("fs_read", id: "peer-after-handoff", arguments: arguments, session: peer,
            credential: fixture.peerCredential)
        XCTAssertEqual(samePeer["content"] as? String, "native source marker two")
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testRevocationRejectsExistingSessionAndCachedSourceRead() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let session = try fixture.initializeReady(credential: fixture.credential)
        let read = try fixture.call("fs_read", id: "cached", arguments: ["path": fixture.file.path], session: session)
        XCTAssertEqual(read["content"] as? String, "native source marker one")
        let revoke = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: fixture.taskID,
            capabilityID: fixture.credential.capabilityID, projectID: fixture.projectID,
            projectGeneration: .initial, expectedEpoch: 1)
        _ = try await fixture.app.projectContexts.repository.revokeNativeContinuityTask(request: revoke)
        let blocked = try fixture.rpc(["jsonrpc": "2.0", "id": "cached", "method": "tools/call",
            "params": ["name": "fs_read", "arguments": ["path": fixture.file.path]]], session: session)
        XCTAssertEqual(blocked.1.statusCode, 401)
        XCTAssertFalse(String(decoding: blocked.0, as: UTF8.self).contains("native source marker"))
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testLostSourceResultsReplayAfterAppAndProtocolSessionRestart() async throws {
        var fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        var session = try fixture.initializeReady(credential: fixture.credential)
        let softMessage: [String: Any] = ["jsonrpc": "2.0", "id": "durable-soft", "method": "tools/call",
            "params": ["name": "session_checkpoint", "arguments": ["goal": "Lost response source checkpoint"]]]
        // Retain the observed wire bytes as test evidence only. The reconnecting
        // caller has its original RPC ID and static source namespace, no returned
        // continuity identifier or inferred latest-packet lookup.
        let lostSoft = try fixture.rpc(softMessage, session: session)
        XCTAssertEqual(lostSoft.1.statusCode, 200)
        var drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
        fixture = try fixture.reopened()
        let firstSession = session
        session = try fixture.initializeReady(credential: fixture.credential)
        XCTAssertNotEqual(firstSession, session)
        let recoveredSoft = try fixture.rpc(softMessage, session: session)
        XCTAssertEqual(recoveredSoft.0, lostSoft.0, "Restart must recover the same soft checkpoint, not construct another packet")
        let object = try JSONSupport.object(from: recoveredSoft.0)
        let payload = try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let continuityID = try XCTUnwrap(payload["continuity_id"] as? String)
        let conflict = try fixture.call("session_checkpoint", id: "durable-soft",
            arguments: ["goal": "Changed request under the same durable identity"], session: session)
        XCTAssertEqual(conflict["code"] as? String, "source_request_conflict")

        let peerSession = try fixture.initializeReady(credential: fixture.peerCredential)
        let peer = try fixture.call("session_checkpoint", id: "durable-soft",
            arguments: ["goal": "Lost response source checkpoint"], session: peerSession,
            credential: fixture.peerCredential)
        XCTAssertNotEqual(peer["continuity_id"] as? String, continuityID,
                          "A static source namespace cannot select another capability's durable request")

        let readyMessage: [String: Any] = ["jsonrpc": "2.0", "id": "durable-ready", "method": "tools/call",
            "params": ["name": "session_handoff", "arguments": ["handoff_id": continuityID]]]
        let lostReady = try fixture.rpc(readyMessage, session: session)
        XCTAssertEqual(lostReady.1.statusCode, 200)
        drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
        fixture = try fixture.reopened()
        session = try fixture.initializeReady(credential: fixture.credential)
        let recoveredReady = try fixture.rpc(readyMessage, session: session)
        XCTAssertEqual(recoveredReady.0, lostReady.0, "The ready source fence must permit only the exact retained request replay")
        let fenced = try fixture.call("session_checkpoint", id: "new-source-after-ready",
            arguments: ["goal": "Forbidden source work"], session: session)
        XCTAssertEqual(fenced["code"] as? String, "source_fenced")
        let started = try fixture.call("clu_start_handoff", id: "recovered-start",
            arguments: ["continuity_id": continuityID], session: session)
        XCTAssertEqual(started["ok"] as? Bool, true, "\(started)")
        XCTAssertNotNil(started["operation_id"] as? String)
        drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }
}

private final class NativeSourceHTTPFixture {
    let root: URL
    let sourceSessionID: UUID
    let app: ForgeApp
    let server: DashboardServer
    let service: MCPTaskHTTPService
    let credential: NativeTaskCapabilityCredential
    let peerCredential: NativeTaskCapabilityCredential
    let taskID: UUID
    let projectID: ProjectID
    let file: URL
    let outside: URL
    let url: URL

    private init(root: URL, app: ForgeApp, credential: NativeTaskCapabilityCredential,
                 peerCredential: NativeTaskCapabilityCredential, taskID: UUID, projectID: ProjectID,
                 file: URL, outside: URL, sourceSessionID: UUID = UUID(), sourceManagerInstanceID: UUID? = nil) throws {
        self.sourceSessionID = sourceSessionID
        self.root = root; self.app = app; self.credential = credential; self.peerCredential = peerCredential
        self.taskID = taskID; self.projectID = projectID; self.file = file; self.outside = outside
        if let sourceManagerInstanceID {
            service = MCPTaskHTTPService(clock: app.clock) { credential, cancellation in
                let attachment = try await app.projectContexts.repository.authenticateNativeTaskCapability(
                    credential: credential, cancellation: cancellation)
                return try MCPNativeTaskSourceDispatcher(app: app, attachment: attachment, managerInstanceID: sourceManagerInstanceID)
            }
        } else {
            service = MCPTaskHTTPService(app: app)
        }
        service.setOperational(true)
        let port = UInt16.random(in: 29_000...39_000)
        server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        server.taskHTTPService = service
        url = URL(string: "http://127.0.0.1:\(port)/mcp/continuity")!
        try server.start()
    }

    static func create(sourceManagerInstanceID: UUID? = nil) async throws -> NativeSourceHTTPFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-native-http-source-\(UUID())")
            .resolvingSymlinksInPath().standardizedFileURL
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("source.txt"), outside = root.appendingPathComponent("outside.txt")
        try Data("native source marker one".utf8).write(to: file)
        try Data("private outside marker".utf8).write(to: outside)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        do {
            _ = try app.config.update(["allowed_roots": [project.path]])
            let policy = try app.config.budgetPolicySelection(scope: .globalDefault)
            _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: policy.revision,
                expectedGlobalRevision: policy.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
            let initialized = try app.projectMemory.initializeUnchecked(path: project.path)
            let projectID = ProjectID(try XCTUnwrap((initialized["project_id"] as? String).flatMap(UUID.init(uuidString:))))
            _ = try await app.projectContexts.repository.registerProjectUnchecked(projectID: projectID,
                displayName: "Native HTTP source", canonicalRoot: project)
            let scope = ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"],
                networkAllowed: false, maximumInlineOutputBytes: 65_536)
            let approval = try NativeContinuityTaskApproval(assignmentID: "native-http-source",
                assignmentBytes: Data("Read the approved source file".utf8), mission: "Read the approved source file",
                providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/source-model",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic,
                filesystemAccess: "read_only", networkAllowed: false, maximumInlineOutputBytes: 65_536,
                sourceLimits: .init(maximumCalls: 8, maximumResultBytes: 65_536, maximumRequestSeconds: 30))
            let assignment = try ContinuityTaskAssignment(assignmentID: approval.assignmentID,
                assignmentBytes: approval.assignmentBytes, mission: approval.mission, providerID: approval.providerID,
                adapterID: approval.adapterID, modelKey: approval.modelKey,
                specification: .init(allowedTools: approval.allowedTools, completionGates: approval.completionGates,
                    resourceProfile: approval.resourceProfile), authorizationScope: scope)
            let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 11, count: 32))
            let peer = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 19, count: 32))
            let taskID = UUID()
            for (id, value) in [(taskID, credential), (UUID(), peer)] {
                let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: id,
                    capabilityID: value.capabilityID, projectID: projectID, projectGeneration: .initial,
                    approval: approval, verifierSHA256: value.verifier.sha256,
                    expiresAt: ISO8601.string(from: Date().addingTimeInterval(3600)))
                _ = try await app.projectContexts.repository.prepareNativeContinuityTask(request: request, approvedAssignment: assignment)
            }
            return try Self(root: root, app: app, credential: credential, peerCredential: peer,
                taskID: taskID, projectID: projectID, file: file, outside: outside, sourceManagerInstanceID: sourceManagerInstanceID)
        } catch { app.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }

    func reopened() throws -> NativeSourceHTTPFixture {
        server.stop()
        app.shutdown()
        let restored = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        return try Self(root: root, app: restored, credential: credential, peerCredential: peerCredential,
            taskID: taskID, projectID: projectID, file: file, outside: outside, sourceSessionID: sourceSessionID)
    }

    func stop() { server.stop(); app.shutdown(); try? FileManager.default.removeItem(at: root) }
    func rpc(_ object: [String: Any], session: String? = nil,
             credential: NativeTaskCapabilityCredential? = nil) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sourceSessionID.uuidString.lowercased(), forHTTPHeaderField: "Forge-Source-Session-ID")
        request.setValue("Bearer " + (credential ?? self.credential).authorizationValue, forHTTPHeaderField: "Authorization")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(MCPTaskHTTPService.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSupport.data(from: object)
        return try HTTPTestHelpers.fetch(request)
    }
    func call(_ name: String, id: String, arguments: [String: Any], session: String,
              credential: NativeTaskCapabilityCredential? = nil) throws -> [String: Any] {
        let response = try rpc(["jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]], session: session, credential: credential)
        XCTAssertEqual(response.1.statusCode, 200)
        let object = try JSONSupport.object(from: response.0)
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"] as? [String: Any], "\(object)")
    }
    func initializeReady(credential: NativeTaskCapabilityCredential) throws -> String {
        let response = try rpc(["jsonrpc": "2.0", "id": UUID().uuidString, "method": "initialize",
            "params": ["protocolVersion": MCPTaskHTTPService.protocolVersion]], credential: credential)
        XCTAssertEqual(response.1.statusCode, 200)
        let session = try XCTUnwrap(response.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(try rpc(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session,
            credential: credential).1.statusCode, 202)
        return session
    }
}

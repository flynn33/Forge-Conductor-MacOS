import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class MCPNativeTaskSourceTests: XCTestCase, @unchecked Sendable {
    func testAcceptedNativeReadRejectsInsufficientOutputReservationThenReplaysExactPackResult() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let call = try await fixture.acceptedNativeCall(lease: lease, name: "fs_read", arguments: ["path": fixture.file.path])
        let insufficient = try call.outputBudget(maximumBytes: 65_535, escapedBytes: 393_216)
        do {
            _ = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
                lease: lease, outputBudget: insufficient, cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Read executed without reserving its full approved output ceiling")
        } catch let error as NativeSourceConversationError { XCTAssertEqual(error, .budgetExceeded) }
        let absent = try await fixture.app.projectContexts.repository.nativeSourceProviderCallOutput(reference: call.reference,
            credential: fixture.credential, lease: lease, policySelection: fixture.policy())
        XCTAssertNil(absent)
        let result = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: call.outputBudget(), cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(try JSONSupport.object(from: result.canonicalPayloadJSON)["content"] as? String, "native source marker one")
        XCTAssertEqual(result.callID, "call_native_fixture")
        XCTAssertEqual(JSONSupport.sha256Hex(result.canonicalPayloadJSON), result.payloadSHA256)
        XCTAssertEqual(JSONSupport.sha256Hex(result.canonicalToolResultJSON), result.resultSHA256)
        try Data("Replacement must not be read on receipt replay".utf8).write(to: fixture.file)
        let replay = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: call.outputBudget(), cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(replay.reservationID, result.reservationID)
        XCTAssertEqual(replay.canonicalToolResultJSON, result.canonicalToolResultJSON)
        do {
            _ = try await fixture.service.submitNativeCall(credential: fixture.peerCredential, reference: call.reference,
                lease: lease, outputBudget: call.outputBudget(), cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Peer capability acquired original native output")
        } catch { }
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testNativeSoftCheckpointReservesActualEscapedOutputBeforeSourceCommit() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let call = try await fixture.acceptedNativeCall(lease: lease, name: "session_checkpoint",
            arguments: ["goal": "Bounded quoted progress \"source\" / 雪"])
        do {
            _ = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
                lease: lease, outputBudget: call.outputBudget(escapedBytes: 1), cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Soft checkpoint mutated source before reserving its escaped provider output")
        } catch let error as NativeSourceConversationError { XCTAssertEqual(error, .budgetExceeded) }
        let result = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: call.outputBudget(), cancellation: ToolCallCancellation(timeoutSeconds: 5))
        let payload = try JSONSupport.object(from: result.canonicalPayloadJSON)
        XCTAssertEqual(payload["revision"] as? Int, 1, "A rejected preflight must not commit an earlier source revision")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertFalse(result.readyHandoffCommitted)
        let replay = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: call.outputBudget(), cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(replay.canonicalToolResultJSON, result.canonicalToolResultJSON)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testNativeReadyHandoffRetainsReceiptWithoutRequiringProviderContinuationBudget() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let call = try await fixture.acceptedNativeCall(lease: lease, name: "session_handoff",
            arguments: ["goal": "Frozen native source ready for successor"])
        let tiny = try call.outputBudget(maximumBytes: 1, escapedBytes: 1)
        let result = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: tiny, cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertTrue(result.readyHandoffCommitted)
        XCTAssertEqual(try JSONSupport.object(from: result.canonicalPayloadJSON)["ok"] as? Bool, true)
        let replay = try await fixture.service.submitNativeCall(credential: fixture.credential, reference: call.reference,
            lease: lease, outputBudget: tiny, cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(replay.canonicalToolResultJSON, result.canonicalToolResultJSON)
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testNativeAndRealHTTPExecutionShareCapacityAndCancellationChannels() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let call = try await fixture.acceptedNativeCall(lease: lease, name: "fs_read", arguments: ["path": fixture.file.path])
        let gate = NativeBridgeTestGate()
        defer { gate.release() }
        let app = fixture.app
        let service = MCPTaskHTTPService(clock: app.clock) { credential, cancellation in
            let attachment = try await app.projectContexts.repository.authenticateNativeTaskCapability(
                credential: credential, cancellation: cancellation)
            return NativeBridgeHeldDispatcher(base: try MCPNativeTaskSourceDispatcher(app: app,
                attachment: attachment, managerInstanceID: UUID()), gate: gate)
        }
        service.setOperational(true)
        fixture.server.stop(); fixture.server.taskHTTPService = service; try fixture.server.start()
        let session = try fixture.initializeReady(credential: fixture.credential)
        let credential = fixture.credential
        let reference = call.reference
        let budget = try call.outputBudget()
        let nativeToken = ToolCallCancellation(timeoutSeconds: 10)
        gate.hold()
        let native = Task { try await service.submitNativeCall(credential: credential, reference: reference,
            lease: lease, outputBudget: budget, cancellation: nativeToken) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 10
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let requests = try (0..<7).map { index in try fixture.request(
            ["jsonrpc": "2.0", "id": index == 0 ? "call_native_fixture" : "held-http-\(index)", "method": "tools/call",
             "params": ["name": "fs_read", "arguments": ["path": fixture.file.path]]], session: session) }
        let http = requests.map { request in Task { try await client.data(for: request) } }
        try await gate.waitForEntries(8)
        XCTAssertEqual(service.retainedWorkCount, 8)
        let duplicateToken = ToolCallCancellation(timeoutSeconds: 5)
        do {
            _ = try await service.submitNativeCall(credential: credential, reference: reference,
                lease: lease, outputBudget: budget, cancellation: duplicateToken)
            XCTFail("A duplicate acquired the original native execution")
        } catch let error as MCPNativeSourceBridgeError { XCTAssertEqual(error, .duplicateActiveRequest) }
        duplicateToken.cancel()
        XCTAssertNoThrow(try nativeToken.checkCancellation())
        let overflow = try fixture.rpc(["jsonrpc": "2.0", "id": "execution-overflow", "method": "tools/list"], session: session)
        XCTAssertEqual(overflow.1.statusCode, 503)
        let cancelled = try fixture.rpc(["jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": "call_native_fixture"]], session: session)
        XCTAssertEqual(cancelled.1.statusCode, 202)
        XCTAssertNoThrow(try nativeToken.checkCancellation(), "Protocol cancellation must not target the native call with the same text ID")
        XCTAssertEqual(service.retainedWorkCount, 8)
        service.setOperational(false)
        XCTAssertThrowsError(try nativeToken.checkCancellation())
        XCTAssertEqual(service.retainedWorkCount, 8, "Cancelled executions stay admitted until actual exit")
        gate.release()
        do { _ = try await native.value; XCTFail("Stopped native worker disclosed output") } catch { }
        for task in http { _ = try? await task.value }
        let drained = await service.shutdown()
        XCTAssertTrue(drained)
        let output = try await fixture.app.projectContexts.repository.nativeSourceProviderCallOutput(reference: reference,
            credential: credential, lease: lease, policySelection: fixture.policy())
        XCTAssertNil(output, "Cancellation before dispatch must not manufacture a completed source read")
    }

    func testNativeCatalogUsesLiveTaskLeaseAndExactThreeTools() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let tools = try await fixture.service.nativeProviderTools(credential: fixture.credential,
            lease: lease, cancellation: ToolCallCancellation(timeoutSeconds: 5))
        XCTAssertEqual(Set(try tools.compactMap { try JSONSupport.object(from: $0)["name"] as? String }),
            MCPNativeTaskSourceProfile.sourceToolNames)
        XCTAssertEqual(tools, try MCPNativeTaskSourceProfile.providerToolDefinitions(
            catalog: .production(toolNames: fixture.app.tools.toolNames)))
        let session = try fixture.initializeReady(credential: fixture.credential)
        let ownerManaged = try fixture.call("fs_read", id: "http-after-enrollment",
            arguments: ["path": fixture.file.path], session: session)
        XCTAssertEqual(ownerManaged["code"] as? String, "source_owner_managed")
        XCTAssertNil(ownerManaged["content"])
        let controls = try fixture.call("clu_capabilities", id: "controls-after-enrollment", arguments: [:], session: session)
        XCTAssertEqual(controls["ok"] as? Bool, true)

        do {
            _ = try await fixture.service.nativeProviderTools(credential: fixture.peerCredential,
                lease: lease, cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("A peer capability acquired the original task's tools")
        } catch { }
        fixture.service.setOperational(false)
        do {
            _ = try await fixture.service.nativeProviderTools(credential: fixture.credential,
                lease: lease, cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Stopped service admitted native source work")
        } catch let error as MCPNativeSourceBridgeError { XCTAssertEqual(error, .stopped) }
        fixture.service.setOperational(true)
        let revoke = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: fixture.taskID,
            capabilityID: fixture.credential.capabilityID, projectID: fixture.projectID,
            projectGeneration: .initial, expectedEpoch: 1)
        _ = try await fixture.app.projectContexts.repository.revokeNativeContinuityTask(request: revoke)
        do {
            _ = try await fixture.service.nativeProviderTools(credential: fixture.credential,
                lease: lease, cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Revoked source capability remained admitted")
        } catch { }
        let drained = await fixture.service.shutdown()
        XCTAssertTrue(drained)
    }

    func testNativeAndRealHTTPAuthenticationShareCapacityAndRetainOldEpochUntilExit() async throws {
        let fixture = try await NativeSourceHTTPFixture.create()
        defer { fixture.stop() }
        let lease = try await fixture.enrollAndLease()
        let gate = NativeBridgeTestGate()
        defer { gate.release() }
        let app = fixture.app
        let service = MCPTaskHTTPService(clock: app.clock) { credential, cancellation in
            await gate.waitIfHeld()
            try cancellation.checkCancellation()
            let attachment = try await app.projectContexts.repository.authenticateNativeTaskCapability(
                credential: credential, cancellation: cancellation)
            return try MCPNativeTaskSourceDispatcher(app: app, attachment: attachment, managerInstanceID: UUID())
        }
        service.setOperational(true)
        fixture.server.stop(); fixture.server.taskHTTPService = service; try fixture.server.start()
        let session = try fixture.initializeReady(credential: fixture.credential)
        gate.hold()
        let credential = fixture.credential
        let native = (0..<4).map { _ in Task {
            try await service.nativeProviderTools(credential: credential, lease: lease,
                cancellation: ToolCallCancellation(timeoutSeconds: 5))
        } }
        let requests = try (0..<4).map { index in try fixture.request(
            ["jsonrpc": "2.0", "id": "held-\(index)", "method": "tools/list"], session: session) }
        let http = requests.map { request in Task { try await URLSession.shared.data(for: request) } }
        try await gate.waitForEntries(8)
        XCTAssertEqual(service.retainedWorkCount, 8)
        do {
            _ = try await service.nativeProviderTools(credential: credential, lease: lease,
                cancellation: ToolCallCancellation(timeoutSeconds: 5))
            XCTFail("Ninth authentication bypassed the shared pool")
        } catch let error as MCPNativeSourceBridgeError { XCTAssertEqual(error, .authenticationCapacity) }
        let overflow = try fixture.rpc(["jsonrpc": "2.0", "id": "overflow", "method": "tools/list"], session: session)
        XCTAssertEqual(overflow.1.statusCode, 503)
        fixture.server.stop(); try fixture.server.start()
        XCTAssertEqual(service.retainedWorkCount, 8, "A rebind must retain cancelled Tasks until actual exit")
        gate.release()
        for task in native {
            do { _ = try await task.value; XCTFail("Old listener epoch delivered native tools") } catch { }
        }
        for task in http { _ = try? await task.value }
        let drained = await service.shutdown()
        XCTAssertTrue(drained)
        XCTAssertEqual(service.retainedWorkCount, 0)
    }

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

final class NativeSourceHTTPFixture {
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

    struct AcceptedCall {
        let reference: NativeSourceProviderCallReference
        let resolved: ResolvedNativeSourceProviderCall
        let preflight: ProviderRequestPreflight
        func outputBudget(maximumBytes: Int = 65_536, escapedBytes: Int = 393_216) throws -> NativeSourceProviderOutputBudget {
            try .init(conversationID: reference.conversationID, stageID: reference.stageID,
                callOrdinal: reference.ordinal, configurationFingerprintSHA256: preflight.configurationFingerprintSHA256,
                priorOutputsSHA256: resolved.priorOutputsSHA256, maximumCanonicalToolResultBytes: maximumBytes,
                maximumEscapedPayloadBytes: escapedBytes, maximumResultTokens: 4_096)
        }
    }

    func policy() throws -> BudgetPolicySelection {
        try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
    }

    /// Scripted provider evidence passes through actual durable turn admission.
    /// Local native transport preflight performs no inventory/auth/provider I/O.
    func acceptedNativeCall(lease: NativeSourceConversationLease, name: String,
                            arguments: [String: Any]) async throws -> AcceptedCall {
        let repository = app.projectContexts.repository
        let tools = try await service.nativeProviderTools(credential: credential, lease: lease,
            cancellation: ToolCallCancellation(timeoutSeconds: 5))
        let prepared = try await repository.prepareNativeSourceProviderTurn(request: .init(requestID: UUID(),
            conversationID: lease.conversationID, userInput: "Fixture approved source work"),
            credential: credential, lease: lease, tools: tools)
        guard case .root(let rootRequest) = prepared.request else { throw NativeSourceConversationError.conflict }
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/source-model", maximumOutputTokens: 64)))
        let preflight = try await provider.preflightRoot(rootRequest)
        let capabilities = try ProviderCapabilities(providerID: "lmstudio", providerVersion: "fixture-1",
            modelKey: "fixture/source-model", providerInstanceID: "fixture-source-instance",
            contextLength: 262_144, maximumContextLength: 262_144, statefulResponses: true, streaming: true,
            customTools: true, mcp: false, structuredOutput: true, usageReporting: true,
            idempotencyLookup: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64))
        let check = try await repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: preflight,
            credential: credential, lease: lease)
        try await repository.finishNativeSourceCapabilityCheck(claim: check, capabilities: capabilities, outcome: .completed,
            credential: credential, lease: lease)
        let retained = try ContextBudgetMath.estimateTokens(serializedBytes: preflight.bodyByteCount, policy: ContextBudgetPolicy())
        let selection = try policy()
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities, selection: selection)
        let reserve = try configuration.reserves.fixedTotal()
        let ceilings = NativeSourceBudgetCeilings(effectiveContextTokens: configuration.capacity.capacity,
            maximumOutputTokens: preflight.limits.maximumOutputTokens, tools: selection.policy.tools,
            reserves: configuration.reserves, checkpointRatio: selection.policy.context.checkpointRatio,
            rolloverRatio: selection.policy.context.rolloverRatio, emergencyRatio: selection.policy.context.emergencyRatio)
        let accounting = try ContextBudgetAccounting(version: "admitted_total_v2", cut: "retained_input_before_next_operation",
            retainedInputTokens: retained, futureReserveTokens: reserve, resolvedPolicy: configuration.resolvedPolicy)
        let budget = try NativeSourceProviderBudgetApproval(policySelection: selection, effectiveContextTokens: configuration.capacity.capacity,
            retainedInputTokens: retained, futureReserveTokens: reserve, limits: preflight.limits, ceilings: ceilings,
            accounting: accounting, source: .serializedEstimate, confidence: 0.5, action: .normal)
        let admission = try await repository.beginNativeSourceProviderPost(prepared: prepared, preflight: preflight,
            capabilities: capabilities, budget: budget, credential: credential, lease: lease)
        guard case .dispatch(let claim) = admission else { throw NativeSourceConversationError.conflict }
        let turn = try ProviderTurn(requestID: prepared.stageID.uuidString.lowercased(), responseID: "resp_native_fixture",
            providerID: "lmstudio", providerVersion: capabilities.providerVersion, modelKey: "fixture/source-model",
            providerInstanceID: capabilities.providerInstanceID, messages: [],
            toolCalls: [.init(callID: "call_native_fixture", name: name,
                argumentsJSON: ForgeJSONCanonicalizationV1.data(from: arguments))],
            usage: .init(capacity: 262_144, inputTokens: retained, outputTokens: 20, source: .providerExact, confidence: 1),
            completed: true, finishReason: .toolCalls)
        let accepted = try await repository.acceptNativeSourceProviderTurn(claim: claim, turn: turn,
            credential: credential, lease: lease)
        let reference = try XCTUnwrap(accepted.calls.first)
        let resolved = try await repository.resolveNativeSourceProviderCall(reference: reference,
            credential: credential, lease: lease)
        return .init(reference: reference, resolved: resolved, preflight: preflight)
    }

    func enrollAndLease() async throws -> NativeSourceConversationLease {
        let policy = try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
        let conversation = try await app.projectContexts.repository.enrollNativeSourceConversation(
            requestID: UUID(), taskID: taskID, credential: credential, policySelection: policy)
        return try await app.projectContexts.repository.acquireNativeSourceConversationLease(
            conversationID: conversation.conversationID, credential: credential, managerInstanceID: UUID())
    }

    func stop() { server.stop(); app.shutdown(); try? FileManager.default.removeItem(at: root) }
    func rpc(_ object: [String: Any], session: String? = nil,
             credential: NativeTaskCapabilityCredential? = nil) throws -> (Data, HTTPURLResponse) {
        try HTTPTestHelpers.fetch(request(object, session: session, credential: credential))
    }
    func request(_ object: [String: Any], session: String? = nil,
                 credential: NativeTaskCapabilityCredential? = nil) throws -> URLRequest {
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
        return request
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

/// A finite test barrier deliberately keeps cancelled work alive until released,
/// making ownership retention observable without timing a cooperative worker.
private final class NativeBridgeTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var entries = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func hold() { lock.lock(); held = true; lock.unlock() }
    func waitIfHeld() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held { entries += 1; continuations.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
    }
    func release() {
        lock.lock(); held = false; let pending = continuations; continuations.removeAll(); lock.unlock()
        for continuation in pending { continuation.resume() }
    }
    private var count: Int { lock.lock(); defer { lock.unlock() }; return entries }
    func waitForEntries(_ expected: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while count < expected {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                release(); throw NSError(domain: "NativeBridgeTestGate", code: 1)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private struct NativeBridgeHeldDispatcher: MCPNativeSourceDispatching {
    let base: MCPNativeTaskSourceDispatcher
    let gate: NativeBridgeTestGate
    var sessionBindingSHA256: String { base.sessionBindingSHA256 }
    var expiresAt: Date { base.expiresAt }
    func toolDescriptorsJSON() throws -> Data { try base.toolDescriptorsJSON() }
    func call(name: String, argumentsJSON: Data, identity: MCPTaskRequestIdentity,
              cancellation: ToolCallCancellation) async throws -> ToolResult {
        await gate.waitIfHeld()
        try cancellation.checkCancellation()
        return try await base.call(name: name, argumentsJSON: argumentsJSON, identity: identity, cancellation: cancellation)
    }
    func nativeProviderTools(credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
                             cancellation: ToolCallCancellation) async throws -> [Data] {
        try await base.nativeProviderTools(credential: credential, lease: lease, cancellation: cancellation)
    }
    func resolveNativeProviderCall(reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
                                   lease: NativeSourceConversationLease, cancellation: ToolCallCancellation) async throws -> ResolvedNativeSourceProviderCall {
        try await base.resolveNativeProviderCall(reference: reference, credential: credential, lease: lease, cancellation: cancellation)
    }
    func submitNativeCall(resolved: ResolvedNativeSourceProviderCall, credential: NativeTaskCapabilityCredential,
                          lease: NativeSourceConversationLease, outputBudget: NativeSourceProviderOutputBudget,
                          preparedCheckpoint: PreparedContinuitySourceCommit?, cancellation: ToolCallCancellation) async throws -> NativeSourceProviderCallOutput {
        await gate.waitIfHeld()
        try cancellation.checkCancellation()
        return try await base.submitNativeCall(resolved: resolved, credential: credential, lease: lease,
            outputBudget: outputBudget, preparedCheckpoint: preparedCheckpoint, cancellation: cancellation)
    }
}

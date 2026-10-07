import Foundation
import Synchronization
import XCTest
@testable import ForgeConductorCore

final class WebRendererServiceTests: XCTestCase {
    func testSupportedOSGateDoesNotRaiseWholeProductDeploymentTarget() {
        XCTAssertFalse(WebRendererService.supports(OperatingSystemVersion(majorVersion: 26, minorVersion: 9, patchVersion: 9)))
        XCTAssertTrue(WebRendererService.supports(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
    }

    func testCompleteAdmittedReplyReturnsOnlyAfterBothEOFsAndConfirmedTermination() async throws {
        try requireSupported()
        let transport = FixtureTransport()
        let service = WebRendererService(transport: transport)
        let request = makeRequest()
        let reply = try await service.execute(request, cancellation: ToolCallCancellation(timeoutSeconds: 10))
        XCTAssertEqual(reply.text, "DOM marker 😀")
        XCTAssertEqual(reply.nonce, request.nonce)
        XCTAssertEqual(transport.count, 1)
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
        XCTAssertEqual(transport.recoveryCount, 0)
    }

    func testIncompleteTransportDispositionNeverBecomesSuccessfulSnapshot() async throws {
        try requireSupported()
        let invalid: [FixtureTransport.Mode] = [.stdoutReadError, .stderrForcedClose, .stdoutTruncated,
            .stderrTruncated, .stdinPartial, .stdinOpen, .exitFailure, .signalled, .termRequested,
            .killRequested, .duplicateFrame, .wrongNonce, .wrongProject, .wrongGeneration, .oversizedStdout]
        for mode in invalid {
            let transport = FixtureTransport(mode: mode)
            let service = WebRendererService(transport: transport)
            do {
                _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
                XCTFail("Accepted incomplete disposition: \(mode)")
            } catch { XCTAssertEqual(error as? WebRenderError, .invalidResponse, "\(mode)") }
            let stopped = await service.shutdown()
            XCTAssertTrue(stopped, "Confirmed failed child must release the service slot: \(mode)")
            XCTAssertEqual(transport.recoveryCount, 0)
        }
    }

    func testBusyRequestDoesNotSpawnOrQueueAndSlotCanBeReusedAfterCompletion() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .hold)
        let service = WebRendererService(transport: transport)
        let firstRequest = makeRequest()
        let first = Task { try await service.execute(firstRequest, cancellation: ToolCallCancellation(timeoutSeconds: 10)) }
        try await waitUntil { transport.count == 1 }
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("A second request must fail busy")
        } catch { XCTAssertEqual(error as? WebRenderError, .busy) }
        XCTAssertEqual(transport.count, 1)
        transport.setMode(.normal)
        transport.release()
        let completed = try await first.value
        XCTAssertEqual(completed.nonce, firstRequest.nonce)
        let thirdRequest = makeRequest()
        let third = try await service.execute(thirdRequest, cancellation: ToolCallCancellation(timeoutSeconds: 10))
        XCTAssertEqual(third.nonce, thirdRequest.nonce)
        XCTAssertEqual(transport.count, 2)
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
    }

    func testNativeAdmissionRejectionIsActionableAndDistinctFromEarlyChildExit() async throws {
        try requireSupported()
        for mode in [FixtureTransport.Mode.roleRejected, .auditTokenUnavailable, .childInvalid,
                     .exactIdentityMismatch, .throwsIdentity] {
            let transport = FixtureTransport(mode: mode)
            let service = WebRendererService(transport: transport)
            do {
                _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
                XCTFail("Rejected native identity cannot produce a snapshot")
            } catch {
                XCTAssertEqual(error as? WebRenderError, .identityRejected)
                XCTAssertEqual((error as? WebRenderError)?.code, "web_render_identity_rejected")
            }
            let stopped = await service.shutdown()
            XCTAssertTrue(stopped)
        }
        for mode in [FixtureTransport.Mode.notAttempted, .ownedChildExited] {
            let service = WebRendererService(transport: FixtureTransport(mode: mode))
            do {
                _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
                XCTFail("Unadmitted transport cannot produce a snapshot")
            } catch { XCTAssertEqual(error as? WebRenderError, .transportFailed) }
            let stopped = await service.shutdown()
            XCTAssertTrue(stopped)
        }
    }

    func testCancellationUsesSameTokenAndReleasesOnlyConfirmedOwner() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .untilCancelled)
        let service = WebRendererService(transport: transport)
        let control = ToolCallCancellation(timeoutSeconds: 10)
        let request = makeRequest()
        let task = Task { try await service.execute(request, cancellation: control) }
        try await waitUntil { transport.count == 1 }
        control.cancel()
        do { _ = try await task.value; XCTFail("Cancellation cannot return DOM success") }
        catch { XCTAssertEqual(error as? WebRenderError, .cancelled) }
        XCTAssertTrue(transport.observedCancellation)
        transport.setMode(.normal)
        _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
        XCTAssertEqual(transport.count, 2)
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
    }

    func testShutdownCancelsActiveOperationThenPermanentlyStopsAdmission() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .untilCancelled)
        let service = WebRendererService(transport: transport)
        let request = makeRequest()
        let task = Task { try await service.execute(request, cancellation: ToolCallCancellation(timeoutSeconds: 10)) }
        try await waitUntil { transport.count == 1 }
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
        do { _ = try await task.value; XCTFail("Shutdown cancelled operation cannot pass") }
        catch { XCTAssertEqual(error as? WebRenderError, .cancelled) }
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Stopped service must reject later requests")
        } catch { XCTAssertEqual(error as? WebRenderError, .stopped) }
        XCTAssertEqual(transport.count, 1)
    }

    func testUnconfirmedThrowRetainsSlotUntilSeparateConfirmedRecovery() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .throwsUnconfirmed)
        let service = WebRendererService(transport: transport)
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Unconfirmed termination cannot pass")
        } catch { XCTAssertEqual(error as? WebRenderError, .terminationUnconfirmed) }
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Unresolved ownership must remain busy")
        } catch { XCTAssertEqual(error as? WebRenderError, .busy) }
        let unresolved = await service.shutdown()
        XCTAssertFalse(unresolved)
        XCTAssertEqual(transport.recoveryCount, 1)
        transport.setRecoveryConfirmed(true)
        let recovered = await service.shutdown()
        XCTAssertTrue(recovered)
        XCTAssertEqual(transport.recoveryCount, 2)
        XCTAssertEqual(transport.count, 1)
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Recovery must not reopen a stopped service")
        } catch { XCTAssertEqual(error as? WebRenderError, .stopped) }
    }

    func testUnconfirmedRawDispositionCannotFabricateFreeSlot() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .terminalUnconfirmed)
        let service = WebRendererService(transport: transport)
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Unconfirmed owner cannot pass")
        } catch { XCTAssertEqual(error as? WebRenderError, .terminationUnconfirmed) }
        do {
            _ = try await service.execute(makeRequest(), cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("No second spawn is permitted")
        } catch { XCTAssertEqual(error as? WebRenderError, .busy) }
        transport.setRecoveryConfirmed(true)
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
        XCTAssertEqual(transport.count, 1)
    }

    func testExpiredRecoveryDoesNotAddNewWaitGraceOrDeclareCompletion() async throws {
        try requireSupported()
        let transport = FixtureTransport(mode: .delayedUnconfirmed)
        let service = WebRendererService(transport: transport)
        let request = makeRequest(seconds: 3.5)
        do {
            _ = try await service.execute(request, cancellation: ToolCallCancellation(timeoutSeconds: 10))
            XCTFail("Delayed unresolved owner cannot pass")
        } catch { XCTAssertEqual(error as? WebRenderError, .terminationUnconfirmed) }
        let stopped = await service.shutdown()
        XCTAssertFalse(stopped)
        try await waitUntil { transport.recoveryCount == 1 }
        XCTAssertEqual(transport.lastRecoveryDeadline, request.deadlineUptimeNanoseconds)
        transport.setRecoveryConfirmed(true)
        try await waitUntilAsync { await service.shutdown() }
        XCTAssertEqual(transport.recoveryCount, 2)
        XCTAssertEqual(transport.lastRecoveryDeadline, request.deadlineUptimeNanoseconds)
        XCTAssertEqual(transport.count, 1)
    }

    func testInvalidStartupDeadlineAndPrecancelledControlNeverReachTransport() async throws {
        try requireSupported()
        let transport = FixtureTransport()
        let service = WebRendererService(transport: transport)
        for seconds in [1.0, 31.0] {
            do {
                _ = try await service.execute(makeRequest(seconds: seconds), cancellation: ToolCallCancellation(timeoutSeconds: 40))
                XCTFail("Invalid renderer interval must not spawn")
            } catch { XCTAssertEqual(error as? WebRenderError, .deadline) }
        }
        let cancelled = ToolCallCancellation(timeoutSeconds: 10)
        cancelled.cancel()
        do { _ = try await service.execute(makeRequest(), cancellation: cancelled); XCTFail("Cancelled input must not spawn") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.count, 0)
        let stopped = await service.shutdown()
        XCTAssertTrue(stopped)
    }

    func testGrantNetworkAndClientAdmissionAreIndependent() {
        let client = ClientID("render-test")
        let context = makeContext(client: client)
        XCTAssertNil(WebRenderToolPack.admissionFailure(context: context, clientID: client))
        XCTAssertEqual(WebRenderToolPack.admissionFailure(context: nil, clientID: client)?.payload["code"] as? String,
                       "project_context_required")
        XCTAssertEqual(WebRenderToolPack.admissionFailure(context: context, clientID: ClientID("other"))?.payload["code"] as? String,
                       "project_context_required")
        XCTAssertEqual(WebRenderToolPack.admissionFailure(context: makeContext(client: client, tools: ["web.fetch"]),
                                                         clientID: client)?.payload["code"] as? String, "tool_not_granted")
        XCTAssertEqual(WebRenderToolPack.admissionFailure(context: makeContext(client: client, network: false),
                                                         clientID: client)?.payload["code"] as? String, "network_not_authorized")
        XCTAssertNil(WebRenderToolPack.admissionFailure(context: makeContext(client: client, tools: ["*"]), clientID: client))
    }

    func testEncodedMCPBudgetIncludesDuplicateContentAndPreservesUnicodeDigest() throws {
        let context = makeContext()
        let request = makeRequest(project: context.projectID.rawValue, generation: context.projectGeneration.rawValue)
        let reply = makeReply(request, text: String(repeating: "😀\"\\\n", count: 600), title: String(repeating: "😀", count: 128))
        let result = try WebRenderToolPack.snapshotResult(reply, requestedURL: request.url, context: context,
                                                        budget: 3_500, cancellation: nil)
        XCTAssertFalse(result.isError)
        let frame = try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: result)
        XCTAssertLessThanOrEqual(frame.count, 3_500)
        let text = try XCTUnwrap(result.payload["content"] as? String)
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThan(text.utf8.count, reply.text.utf8.count)
        XCTAssertTrue(Data(reply.text.utf8).starts(with: Data(text.utf8)))
        XCTAssertEqual(result.payload["returned_content_bytes"] as? Int, text.utf8.count)
        XCTAssertEqual(result.payload["content_sha256"] as? String, JSONSupport.sha256Hex(Data(text.utf8)))
        XCTAssertEqual(result.payload["truncated"] as? Bool, true)
        XCTAssertEqual(result.payload["javascript_executed"] as? Bool, true)
        XCTAssertEqual(result.payload["whole_network_byte_limit_enforced"] as? Bool, false)
        XCTAssertEqual(result.payload["whole_dom_size_limit_enforced"] as? Bool, false)
        XCTAssertEqual(result.payload["javascript_heap_limit_enforced"] as? Bool, false)
        XCTAssertThrowsError(try WebRenderToolPack.snapshotResult(reply, requestedURL: request.url, context: context,
                                                                 budget: 1, cancellation: nil)) { error in
            XCTAssertEqual(error as? WebRenderError, .outputBudget)
        }
        let control = ToolCallCancellation(timeoutSeconds: 10)
        control.cancel()
        XCTAssertThrowsError(try WebRenderToolPack.snapshotResult(reply, requestedURL: request.url, context: context,
                                                                 budget: 3_500, cancellation: control)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSnapshotRejectsDifferentProjectAndGenerationAtDeliveryBoundary() {
        let context = makeContext()
        for request in [makeRequest(), makeRequest(project: context.projectID.rawValue,
                                                  generation: context.projectGeneration.rawValue + 1)] {
            XCTAssertThrowsError(try WebRenderToolPack.snapshotResult(makeReply(request), requestedURL: request.url,
                                                                     context: context, budget: 16_384, cancellation: nil)) { error in
                XCTAssertEqual(error as? WebRenderError, .invalidResponse)
            }
        }
    }

    func testFinalMCPBudgetUsesActualEscapedIDAndPreservesRequiredPolicyNotice() throws {
        let context = makeContext()
        let request = makeRequest(project: context.projectID.rawValue, generation: context.projectGeneration.rawValue)
        let reply = makeReply(request, text: String(repeating: "😀\"\\\n", count: 600))
        var original = try WebRenderToolPack.snapshotResult(reply, requestedURL: request.url,
            context: context, budget: 16_384, cancellation: nil)
        original.payload["auto_handoff_id"] = "preserved-router-metadata"
        let identifier = String(repeating: "id😀\"\\\n", count: 140)
        let notice = String(repeating: "Required policy notice 😀\n", count: 30)
        let response = WebRenderToolPack.finalMCPResponse(id: identifier, result: original,
            additiveNotice: notice, budget: 6_000)
        XCTAssertEqual(response["id"] as? String, identifier)
        XCTAssertLessThanOrEqual(try JSONSupport.data(from: response).count, 6_000)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let content = try XCTUnwrap(payload["content"] as? String)
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(Data(reply.text.utf8).starts(with: Data(content.utf8)))
        XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(Data(content.utf8)))
        XCTAssertEqual(payload["returned_content_bytes"] as? Int, content.utf8.count)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(payload["auto_handoff_id"] as? String, "preserved-router-metadata")
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.last?["text"] as? String, notice)
    }

    func testFinalMCPBudgetIncludesTerminatingLineFeedAtExactJSONBoundary() throws {
        let context = makeContext()
        let request = makeRequest(project: context.projectID.rawValue, generation: context.projectGeneration.rawValue)
        let reply = makeReply(request, text: String(repeating: "x", count: 1_024))
        let original = try WebRenderToolPack.snapshotResult(reply, requestedURL: request.url,
            context: context, budget: 16_384, cancellation: nil)
        let identifier = "exact-boundary-\"-\\-😀"
        let notice = "Required notice retained at the exact encoding boundary"
        let budget = try MCPToolResponse.data(id: identifier, result: original, additiveNotice: notice).count
        let response = WebRenderToolPack.finalMCPResponse(id: identifier, result: original,
            additiveNotice: notice, budget: budget)
        XCTAssertLessThanOrEqual(try MCPStdioTransport.encode(response).count, budget)
        XCTAssertEqual(response["id"] as? String, identifier)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.last?["text"] as? String, notice)
        let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let content = try XCTUnwrap(payload["content"] as? String)
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(Data(reply.text.utf8).starts(with: Data(content.utf8)))
        XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(Data(content.utf8)))
        XCTAssertEqual(payload["returned_content_bytes"] as? Int, content.utf8.count)
    }

    func testImpossibleMCPEnvelopeReturnsExplicitBudgetFailureWithoutChangingIDOrNotice() throws {
        let identifier = String(repeating: "escaped\"😀", count: 300)
        let notice = "Required notice"
        let response = WebRenderToolPack.finalMCPResponse(id: identifier,
            result: .success(["content": "marker", "content_sha256": "digest"]),
            additiveNotice: notice, budget: 128)
        XCTAssertEqual(response["id"] as? String, identifier)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(payload["code"] as? String, "web_render_output_budget")
        XCTAssertEqual((result["content"] as? [[String: Any]])?.last?["text"] as? String, notice)
    }

    private func requireSupported() throws {
        if !WebRendererService.isSupported { throw XCTSkip("Renderer actor execution is gated to macOS 27+; codec/admission tests remain portable") }
    }
    private func makeRequest(seconds: Double = 10, project: UUID = UUID(), generation: UInt64 = 1) -> WebRenderProtocol.Request {
        WebRenderProtocol.Request(requestID: UUID(), nonce: UUID(), projectID: project, projectGeneration: generation,
            url: "https://example.com/#render", deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000))
    }
    private func makeReply(_ request: WebRenderProtocol.Request, text: String = "DOM marker 😀", title: String = "Native title") -> WebRenderProtocol.Reply {
        WebRenderProtocol.Reply(requestID: request.requestID, nonce: request.nonce, projectID: request.projectID,
            projectGeneration: request.projectGeneration, outcome: .rendered, finalURL: request.url,
            title: title, text: text, nodesVisited: 2, textTruncated: false, titleTruncated: false,
            readiness: .boundedStability, snapshotExtracted: true, lockdownEnabled: true,
            viewLifetime: .released, storeLifetime: .released)
    }
    private func makeContext(client: ClientID = ClientID("render-test"), tools: Set<String> = ["web.render"],
                             network: Bool = true) -> ToolInvocationContext {
        ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: client,
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [], allowedTools: tools,
                                                       networkAllowed: network, maximumInlineOutputBytes: 16_384))
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !predicate() {
            guard DispatchTime.now().uptimeNanoseconds < end else { throw FixtureFailure.waitExpired }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !(await predicate()) {
            guard DispatchTime.now().uptimeNanoseconds < end else { throw FixtureFailure.waitExpired }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum FixtureFailure: Error { case waitExpired, holdExpired }

/// Deterministic native transport disposition fixture. It launches no executable,
/// makes no network request and supplies no admission hook to production.
private final class FixtureTransport: WebRenderTransport {
    enum Mode: Sendable, Equatable {
        case normal, hold, untilCancelled, throwsUnconfirmed, terminalUnconfirmed, delayedUnconfirmed
        case stdoutReadError, stderrForcedClose, stdoutTruncated, stderrTruncated, stdinPartial, stdinOpen
        case exitFailure, signalled, termRequested, killRequested, duplicateFrame, wrongNonce, wrongProject
        case wrongGeneration, oversizedStdout
        case roleRejected, auditTokenUnavailable, childInvalid, exactIdentityMismatch, throwsIdentity
        case notAttempted, ownedChildExited
    }
    private struct State: Sendable {
        var mode: Mode
        var count = 0
        var observedCancellation = false
        var recoveryConfirmed = false
        var recoveryCount = 0
        var lastRecoveryDeadline: UInt64?
    }
    private let state: Mutex<State>
    private let gate = DispatchSemaphore(value: 0)
    init(mode: Mode = .normal) { state = Mutex(State(mode: mode)) }
    var count: Int { state.withLock { $0.count } }
    var observedCancellation: Bool { state.withLock { $0.observedCancellation } }
    var recoveryCount: Int { state.withLock { $0.recoveryCount } }
    var lastRecoveryDeadline: UInt64? { state.withLock { $0.lastRecoveryDeadline } }
    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }
    func setRecoveryConfirmed(_ confirmed: Bool) { state.withLock { $0.recoveryConfirmed = confirmed } }
    func release() { gate.signal() }

    func run(input: Data, deadline: UInt64, cancellation: ToolCallCancellation) throws -> OwnedDuplexResult {
        let mode = state.withLock { value in value.count += 1; return value.mode }
        let request = try WebRenderProtocol.decodeRequestFrame(input)
        if mode == .hold, gate.wait(timeout: .now() + 5) != .success { throw FixtureFailure.holdExpired }
        if mode == .untilCancelled {
            let end = min(deadline, DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            while !cancellation.isCancelled && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.005) }
            state.withLock { $0.observedCancellation = cancellation.isCancelled }
        }
        if mode == .delayedUnconfirmed {
            while DispatchTime.now().uptimeNanoseconds <= deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        if mode == .throwsUnconfirmed || mode == .delayedUnconfirmed {
            throw ProcessRunnerError.terminationUnconfirmed(processIdentifier: 123, signalError: nil)
        }
        if mode == .throwsIdentity { throw OwnedCurrentSelfAdmissionError.associatedCoreUnavailable }
        var wireRequest = request
        if mode == .wrongNonce {
            wireRequest = WebRenderProtocol.Request(requestID: request.requestID, nonce: UUID(), projectID: request.projectID,
                projectGeneration: request.projectGeneration, url: request.url, deadlineUptimeNanoseconds: deadline)
        } else if mode == .wrongProject {
            wireRequest = WebRenderProtocol.Request(requestID: request.requestID, nonce: request.nonce, projectID: UUID(),
                projectGeneration: request.projectGeneration, url: request.url, deadlineUptimeNanoseconds: deadline)
        } else if mode == .wrongGeneration {
            wireRequest = WebRenderProtocol.Request(requestID: request.requestID, nonce: request.nonce, projectID: request.projectID,
                projectGeneration: request.projectGeneration + 1, url: request.url, deadlineUptimeNanoseconds: deadline)
        }
        let reply = WebRenderProtocol.Reply(requestID: wireRequest.requestID, nonce: wireRequest.nonce,
            projectID: wireRequest.projectID, projectGeneration: wireRequest.projectGeneration, outcome: .rendered,
            finalURL: request.url, title: "Native title", text: "DOM marker 😀", nodesVisited: 2,
            textTruncated: false, titleTruncated: false, readiness: .boundedStability, snapshotExtracted: true,
            lockdownEnabled: true, viewLifetime: .released, storeLifetime: .released)
        var frame = try WebRenderProtocol.encodeReply(reply, matching: wireRequest)
        if mode == .duplicateFrame { frame.append(frame) }
        if mode == .oversizedStdout { frame = Data(repeating: 0, count: WebRenderProtocol.maximumReplyBodyBytes + 5) }
        let admission: OwnedAdmissionDisposition
        switch mode {
        case .roleRejected: admission = .roleRejected
        case .auditTokenUnavailable: admission = .auditTokenUnavailable
        case .childInvalid: admission = .childInvalid
        case .exactIdentityMismatch: admission = .exactIdentityMismatch
        case .notAttempted: admission = .notAttempted
        case .ownedChildExited: admission = .ownedChildExited
        default: admission = .admitted
        }
        return OwnedDuplexResult(exitCode: mode == .exitFailure ? 1 : 0,
            terminationSignal: mode == .signalled ? 9 : nil,
            stdout: OwnedCapturedStream(data: frame, end: mode == .stdoutReadError ? .readError(5) : .eof,
                                        truncated: mode == .stdoutTruncated),
            stderr: OwnedCapturedStream(data: Data(), end: mode == .stderrForcedClose ? .forcedClose : .eof,
                                        truncated: mode == .stderrTruncated),
            stdinBytesWritten: mode == .stdinPartial ? input.count - 1 : input.count,
            stdinClosed: mode != .stdinOpen, admission: admission, timedOut: false,
            cancelled: mode == .untilCancelled && cancellation.isCancelled,
            termRequested: mode == .termRequested, killRequested: mode == .killRequested,
            terminationConfirmed: mode != .terminalUnconfirmed)
    }
    func shutdown(deadline: UInt64) -> Bool {
        state.withLock { value in
            value.recoveryCount += 1
            value.lastRecoveryDeadline = deadline
            return value.recoveryConfirmed
        }
    }
}

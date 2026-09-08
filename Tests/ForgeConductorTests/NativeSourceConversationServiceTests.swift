import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class NativeSourceConversationServiceTests: XCTestCase, @unchecked Sendable {
    func testSendReturnsFrozenIntentWhileProbeRetainsCapacityAndReplayPinsInput() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let service = f.service()
            service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Exact private source input")
            let reply = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            XCTAssertEqual(reply.disposition, "accepted")
            try await self.eventually { await f.provider.counts().probes == 1 }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns WHERE state='prepared'"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_capability_checks WHERE state='attempted'"), 1)
            XCTAssertEqual(f.pool.activeCount, 1)
            XCTAssertEqual(f.operations.value, 1)
            let retained = try await f.repository.nativeSourceRequest(taskID: f.taskID, requestID: request.requestID, credential: f.credential)
            guard case .root(let root)? = retained?.request else { return XCTFail("Missing native root intent") }
            XCTAssertTrue(root.input.contains("Immutable assignment document marker"))
            XCTAssertTrue(root.input.contains(request.input))
            XCTAssertFalse(root.input.contains(f.credential.authorizationValue))
            let replay = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            XCTAssertEqual(replay.disposition, "replayed")
            XCTAssertEqual(replay.stageID, reply.stageID)
            do {
                _ = try await service.send(.init(taskID: f.taskID, requestID: request.requestID, input: "Changed input"), cancellation: .init())
                XCTFail("Reused send identity adopted changed input")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .conflict) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM autonomous_runs"), 0)
            let beforeStop = await f.provider.counts()
            XCTAssertEqual(beforeStop.roots, 0)
            let stopped = await service.shutdown(deadline: Date().addingTimeInterval(0.05))
            XCTAssertFalse(stopped.completed, "Cancellation-insensitive provider still owns actual work")
            XCTAssertEqual(f.pool.activeCount, 1)
            XCTAssertEqual(f.operations.value, 1)
            service.setOperational(true)
            do { _ = try await service.send(request, cancellation: .init()); XCTFail("Closed source owner reopened") }
            catch { XCTAssertEqual(error as? NativeSourceOperatorError, .unavailable) }
            await f.provider.release()
            try await self.eventually { !(await service.hasRetainedWork()) }
            XCTAssertEqual(f.pool.activeCount, 0)
            XCTAssertEqual(f.operations.value, 0)
        }
    }

    func testUnknownPostRecoveryUsesOnlyRecordedLookupAndNeverNewProbeOrPost() async throws {
        try await withFixture(mode: .unknownRoot) { f in
            let first = f.service(); first.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Read the approved assignment")
            _ = try await first.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await first.hasRetainedWork()) }
            let initial = await f.provider.counts()
            XCTAssertEqual(initial.roots, 1); XCTAssertEqual(initial.probes, 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns WHERE state='outcome_unknown'"), 1)
            _ = await first.shutdown(deadline: Date().addingTimeInterval(1))
            let resumed = f.service(); resumed.setOperational(true)
            _ = try await resumed.recoverOnce(cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await resumed.hasRetainedWork()) }
            let afterMiss = await f.provider.counts()
            XCTAssertEqual(afterMiss.roots, 1); XCTAssertEqual(afterMiss.probes, 1); XCTAssertEqual(afterMiss.lookups, 1)
            await f.provider.allowRecordedLookup()
            // Discovery is a bounded page cursor. An end page wraps before the next scan.
            for _ in 0..<2 {
                _ = try await resumed.recoverOnce(cancellation: .init(timeoutSeconds: 5))
                try await self.eventually { !(await resumed.hasRetainedWork()) }
            }
            let status = try await resumed.status(.init(taskID: f.taskID, requestID: request.requestID), cancellation: .init())
            XCTAssertEqual(status.stageState, "accepted")
            XCTAssertEqual(status.conversationState, "idle")
            XCTAssertEqual(try JSONSupport.object(from: status.canonicalJSON)["assistant_preview"] as? String, "Retained actual response")
            let completed = await f.provider.counts()
            XCTAssertEqual(completed.roots, 1); XCTAssertEqual(completed.probes, 1)
            XCTAssertEqual(completed.legacyLookups, 0, "Recovery must not enter a lookup that may probe")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM autonomous_runs"), 0)
            _ = await resumed.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testActualReadOutputThenReadyHandoffStopsRemainingBatchWithoutContinuationPreflight() async throws {
        try await withFixture(mode: .readHandoffSuffix, contextLength: 262_144) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Read and preserve the exact handoff")
            _ = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await service.hasRetainedWork()) }
            XCTAssertNil(f.budgetDiagnostics.snapshot().bridgeError)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_requests WHERE method='fs_read' AND state='completed'"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_requests WHERE method='session_handoff' AND state='completed'"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_calls WHERE output_json IS NOT NULL"), 2)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.continuations, 0)
            XCTAssertEqual(counts.continuationPreflights, 1, "Only the actual fs_read output needs a following-envelope measurement")
            XCTAssertEqual(f.pool.activeCount, 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM autonomous_runs"), 0, "Automatic handoff is disabled in this fixture")
            let status = try await service.status(.init(taskID: f.taskID, requestID: request.requestID), cancellation: .init())
            XCTAssertEqual(status.conversationState, "source_fenced")
            let auth = try await f.repository.authenticateNativeTaskCapability(credential: f.credential)
            let handoffID = try XCTUnwrap(f.budgetDiagnostics.snapshot().handoffID)
            let handoff = try XCTUnwrap(f.app.store.continuityLatestRevision(continuityID: handoffID, authorization: auth.setup.record.authorization))
            XCTAssertTrue(String(decoding: handoff.canonicalPacketJSON, as: UTF8.self).contains("actual read observed"))
            do { _ = try await service.send(.init(taskID: f.taskID, requestID: UUID(), input: "Late source work"), cancellation: .init()); XCTFail("Transferred source accepted a new exchange") }
            catch { }
            _ = await service.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testRealToolOutputIsConsumedByOneExactFollowingProviderInput() async throws {
        try await withFixture(mode: .readThenAnswer, contextLength: 262_144) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Read the file and answer")
            _ = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await service.hasRetainedWork()) }
            XCTAssertNil(f.budgetDiagnostics.snapshot().bridgeError)
            let observedInput = await f.provider.continuationInput()
            let continuation = try XCTUnwrap(observedInput)
            let items = try XCTUnwrap(JSONSerialization.jsonObject(with: continuation) as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0]["call_id"] as? String, "source-read")
            let output = try XCTUnwrap(items[0]["output"] as? String)
            let payload = try JSONSupport.object(from: Data(output.utf8))
            XCTAssertEqual(payload["content"] as? String, "actual source bytes")
            XCTAssertNil(payload["payload"], "The provider consumes the exact payload, without a second wire wrapper")
            let status = try await service.status(.init(taskID: f.taskID, requestID: request.requestID), cancellation: .init())
            XCTAssertEqual(status.conversationState, "idle")
            XCTAssertEqual(status.stageState, "accepted")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns"), 2)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_requests"), 1)
            _ = await service.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testFullApprovedReadFitsCanonicalContinuationAt128K() async throws {
        try await withFixture(mode: .readThenAnswer, contextLength: 131_072) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Read the full approved fixture and answer")
            _ = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await service.hasRetainedWork()) }
            let observation = f.budgetDiagnostics.snapshot()
            XCTAssertEqual(observation.read?.approvedResultBytes, 65_536)
            XCTAssertNil(observation.bridgeError, "A valid canonical payload reserves its complete approved ceiling")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_requests WHERE method='fs_read' AND state='completed'"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_calls WHERE output_json IS NOT NULL"), 1)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.roots, 1); XCTAssertEqual(counts.continuations, 1)
            let input = await f.provider.continuationInput()
            XCTAssertNotNil(input, "The actual complete output must be consumed by a following provider request")
            if let input {
                let items = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [[String: Any]])
                let output = try XCTUnwrap(items.first?["output"] as? String)
                XCTAssertEqual(try JSONSupport.object(from: Data(output.utf8))["content"] as? String, "actual source bytes")
            }
            let status = try await service.status(.init(taskID: f.taskID, requestID: request.requestID), cancellation: .init())
            XCTAssertEqual(status.conversationState, "idle"); XCTAssertEqual(status.stageState, "accepted")
            XCTAssertEqual(f.pool.activeCount, 0); XCTAssertEqual(f.operations.value, 0)
            _ = await service.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testFullApprovedReadIsDeniedBeforeEffectWhenContextCannotReserveItsEscapedOutput() async throws {
        try await withFixture(mode: .readThenAnswer, contextLength: 65_536) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Read the approved file")
            _ = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { !(await service.hasRetainedWork()) }
            let observed = f.budgetDiagnostics.snapshot()
            let read = try XCTUnwrap(observed.read)
            XCTAssertEqual(read.contextLength, 65_536)
            XCTAssertEqual(read.approvedResultBytes, 65_536)
            XCTAssertEqual(read.requiredEscapedBytes, 131_072)
            XCTAssertEqual(try ContextBudgetMath.estimateTokens(serializedBytes: read.requiredEscapedBytes,
                policy: ContextBudgetPolicy()), 54_614)
            XCTAssertLessThan(read.maximumCanonicalToolResultBytes, read.approvedResultBytes)
            XCTAssertLessThan(read.maximumEscapedPayloadBytes, read.requiredEscapedBytes)
            XCTAssertEqual(observed.bridgeError, .budgetExceeded)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns WHERE state='accepted'"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_calls"), 1,
                           "Retain the actual provider call identity for reconciliation")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_requests"), 0,
                           "Reject before charging a source-read debit or reading the file")
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_calls WHERE output_json IS NOT NULL"), 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM tool_invocations"), 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM autonomous_runs"), 0)
            XCTAssertTrue(try f.app.store.pendingContinuityHandoffs().isEmpty)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.roots, 1)
            XCTAssertEqual(counts.continuations, 0)
            XCTAssertEqual(counts.continuationPreflights, 1)
            XCTAssertEqual(f.pool.activeCount, 0)
            XCTAssertEqual(f.operations.value, 0)
            _ = await service.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testCancelPersistsExactSendFenceBeforeRetainedProbeOwnerExits() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Cancellable approved input")
            _ = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { await f.provider.counts().probes == 1 }
            let cancel = try NativeSourceCancelRequest(taskID: f.taskID, requestID: request.requestID,
                cancelRequestID: UUID(), reason: "Operator stopped this exchange")
            let result = try await service.cancel(cancel, cancellation: .init(timeoutSeconds: 5))
            XCTAssertEqual(result.disposition, "cancel_requested")
            XCTAssertEqual(result.conversationState, "stopped")
            XCTAssertEqual(result.stageState, "cancelled_before_dispatch")
            XCTAssertEqual(f.pool.activeCount, 1)
            XCTAssertEqual(f.operations.value, 1)
            let replay = try await service.cancel(cancel, cancellation: .init(timeoutSeconds: 5))
            XCTAssertEqual(replay.stageID, result.stageID)
            await f.provider.release()
            try await self.eventually { !(await service.hasRetainedWork()) }
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.roots, 0)
            XCTAssertEqual(f.pool.activeCount, 0)
            XCTAssertEqual(f.operations.value, 0)
            _ = await service.shutdown(deadline: Date().addingTimeInterval(1))
        }
    }

    func testSynchronousStopBeforeAdmissionDoesNotEnrollOrConsumeCapacity() async throws {
        try await withFixture(mode: .answer) { f in
            let service = f.service(); service.setOperational(true); service.setOperational(false)
            do { _ = try await service.send(.init(taskID: f.taskID, requestID: UUID(), input: "Stopped source"), cancellation: .init()); XCTFail("Stopped source admitted") }
            catch { XCTAssertEqual(error as? NativeSourceOperatorError, .unavailable) }
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_conversations"), 0)
            XCTAssertEqual(f.pool.activeCount, 0); XCTAssertEqual(f.operations.value, 0)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.probes, 0); XCTAssertEqual(counts.roots, 0)
            _ = await service.shutdown(deadline: Date())
        }
    }

    func testStopReopenKeepsOldProviderOwnerCancelledUntilActualExit() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let service = f.service(); service.setOperational(true)
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Retained stop boundary")
            let accepted = try await service.send(request, cancellation: .init(timeoutSeconds: 5))
            try await self.eventually { await f.provider.counts().probes == 1 }
            service.setOperational(false)
            service.setOperational(true)
            XCTAssertEqual(f.pool.activeCount, 1)
            XCTAssertEqual(f.operations.value, 1)
            do {
                _ = try await service.send(.init(taskID: f.taskID, requestID: UUID(), input: "Overlapping work"), cancellation: .init())
                XCTFail("Reopen discarded the old cancellation-insensitive owner")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .capacityExceeded) }
            await f.provider.release()
            try await self.eventually { !(await service.hasRetainedWork()) }
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.probes, 1)
            XCTAssertEqual(counts.roots, 0, "Reopening cannot revive an old worker after its probe returns")
            XCTAssertEqual(f.pool.activeCount, 0); XCTAssertEqual(f.operations.value, 0)
            let retained = try await f.repository.nativeSourceRequest(taskID: f.taskID, requestID: request.requestID,
                credential: f.credential)
            XCTAssertEqual(retained?.stageID, accepted.stageID)
            XCTAssertEqual(retained?.state, .prepared)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns"), 1)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_provider_turns WHERE post_json IS NOT NULL"), 0)
            XCTAssertEqual(try f.scalar("SELECT COUNT(*) FROM native_source_capability_checks WHERE state='unknown'"), 1)
        }
    }

    func testOperationGateTransfersCurrentCommandWithoutRetainingCommandCancellation() async throws {
        let gate = NativeSourceOperationGate(); gate.setOperational(true)
        let command = UUID(), token = ToolCallCancellation()
        XCTAssertTrue(gate.register(command, cancellation: token, requiresOperational: true))
        let harness = NativeSourceGateLaunchFixture()
        let result = await harness.launch(gate: gate, commandID: command)
        XCTAssertTrue(result.admitted)
        gate.remove(command)
        token.cancel()
        await result.task.value
        let counts = await harness.counts()
        XCTAssertEqual(counts.started, 1)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.cancelled, 0)
        XCTAssertFalse(result.cancellation.isCancelled, "After successful binding the worker owns its independent deadline")
        gate.remove(result.workID); gate.close()
    }

    func testOperationGateRejectsOldCommandAfterStopReopenBeforeWorkerCanExecute() async throws {
        let gate = NativeSourceOperationGate(); gate.setOperational(true)
        let command = UUID(), token = ToolCallCancellation()
        XCTAssertTrue(gate.register(command, cancellation: token, requiresOperational: true))
        gate.setOperational(false); gate.setOperational(true)
        XCTAssertTrue(gate.isOperational)
        let harness = NativeSourceGateLaunchFixture()
        let result = await harness.launch(gate: gate, commandID: command)
        XCTAssertFalse(result.admitted)
        XCTAssertTrue(result.cancellation.isCancelled)
        XCTAssertTrue(result.task.isCancelled)
        await result.task.value
        let counts = await harness.counts()
        XCTAssertEqual(counts.started, 0, "An actor-inherited worker must be cancelled before its first operation")
        XCTAssertEqual(counts.completed, 0)
        XCTAssertEqual(counts.cancelled, 1)
        gate.remove(command)
        let fresh = UUID()
        XCTAssertTrue(gate.register(fresh, cancellation: .init(), requiresOperational: true))
        let valid = await harness.launch(gate: gate, commandID: fresh)
        XCTAssertTrue(valid.admitted, "Reopen permits a newly registered command")
        await valid.task.value
        gate.remove(valid.workID); gate.remove(fresh); gate.close()
    }

    func testOperationGateRejectsRemovedCancelledExpiredAndNonOperationalCommands() async throws {
        for scenario in NativeSourceGateRejectedCommand.allCases {
            let gate = NativeSourceOperationGate(); gate.setOperational(true)
            let command = UUID()
            let token = ToolCallCancellation(timeoutSeconds: scenario == .expired ? 0 : nil)
            XCTAssertTrue(gate.register(command, cancellation: token, requiresOperational: scenario != .nonOperational))
            switch scenario {
            case .removed: gate.remove(command)
            case .cancelled: token.cancel()
            case .closed: gate.close(); gate.setOperational(true)
            case .expired, .nonOperational: break
            }
            let harness = NativeSourceGateLaunchFixture()
            let result = await harness.launch(gate: gate, commandID: command)
            XCTAssertFalse(result.admitted, "Invalid command authorized work: \(scenario)")
            await result.task.value
            let counts = await harness.counts()
            XCTAssertEqual(counts.started, 0)
            XCTAssertEqual(counts.cancelled, 1)
            gate.remove(command); gate.close()
        }
    }

    func testOperationGateStopCancelsBoundWorkAndWorkCannotAuthorizeAnotherWorker() async throws {
        let gate = NativeSourceOperationGate(); gate.setOperational(true)
        let command = UUID()
        XCTAssertTrue(gate.register(command, cancellation: .init(), requiresOperational: true))
        let harness = NativeSourceGateLaunchFixture()
        let result = await harness.launch(gate: gate, commandID: command, hold: true)
        XCTAssertTrue(result.admitted)
        do {
            try await eventually { await harness.counts().started == 1 }
            let borrowed = await harness.launch(gate: gate, commandID: result.workID)
            XCTAssertFalse(borrowed.admitted, "Only a registered command can authorize the handover")
            await borrowed.task.value
            gate.remove(command)
            gate.setOperational(false); gate.setOperational(true)
            XCTAssertTrue(result.cancellation.isCancelled)
            XCTAssertTrue(result.task.isCancelled)
            await result.task.value
            let counts = await harness.counts()
            XCTAssertEqual(counts.started, 1)
            XCTAssertEqual(counts.completed, 0)
            XCTAssertEqual(counts.cancelled, 2)
            gate.remove(result.workID); gate.close()
        } catch {
            gate.close(); result.task.cancel(); await result.task.value
            throw error
        }
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Bounded source-owner observation did not settle")
        throw NativeSourceConversationError.deadlineExceeded
    }

    private func withFixture(mode: SourceOwnerProvider.Mode, contextLength: Int = 131_072,
        _ body: (SourceOwnerFixture) async throws -> Void) async throws {
        let f = try await SourceOwnerFixture.make(mode: mode, contextLength: contextLength)
        do {
            try await body(f)
            await f.close()
        } catch { await f.close(); throw error }
    }
}

private final class SourceOwnerFixture: @unchecked Sendable {
    let app: ForgeApp
    let repository: ProjectControlPlaneRepository
    let projectID: ProjectID
    let taskID: UUID
    let credential: NativeTaskCapabilityCredential
    let assignment: ContinuityTaskAssignment
    let provider: SourceOwnerProvider
    let bridge: MCPTaskHTTPService
    let pool: NativeProviderWorkAdmission
    let operations = SourceOwnerCounter()
    let budgetDiagnostics = SourceOwnerBudgetDiagnostics()
    private let servicesLock = NSLock()
    private var services: [NativeSourceConversationService] = []

    private init(app: ForgeApp, projectID: ProjectID, taskID: UUID, credential: NativeTaskCapabilityCredential,
        assignment: ContinuityTaskAssignment, provider: SourceOwnerProvider, bridge: MCPTaskHTTPService) throws {
        self.app = app; repository = app.projectContexts.repository; self.projectID = projectID
        self.taskID = taskID; self.credential = credential; self.assignment = assignment
        self.provider = provider; self.bridge = bridge; pool = try .init(limit: 1)
    }
    static func make(mode: SourceOwnerProvider.Mode, contextLength: Int = 131_072) async throws -> SourceOwnerFixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("native-source-owner-\(UUID().uuidString)").resolvingSymlinksInPath()
        let app = try ForgeApp.bootstrap(home: home)
        do {
            let project = home.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("actual source bytes".utf8).write(to: project.appendingPathComponent("source.txt"))
            try app.config.update(["allowed_roots": [project.path]], save: true)
            let repository = app.projectContexts.repository, projectID = ProjectID(), taskID = UUID()
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source owner", canonicalRoot: project)
            let approval = try NativeContinuityTaskApproval(assignmentID: "native-source-owner",
                assignmentBytes: Data("Immutable assignment document marker".utf8), mission: "Read the approved source file",
                providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic,
                filesystemAccess: "read_only", networkAllowed: false, maximumInlineOutputBytes: 65_536,
                sourceLimits: .init(maximumCalls: 64, maximumResultBytes: 65_536, maximumRequestSeconds: 60))
            let assignment = try ContinuityTaskAssignment(assignmentID: approval.assignmentID, assignmentBytes: approval.assignmentBytes,
                mission: approval.mission, providerID: approval.providerID, adapterID: approval.adapterID, modelKey: approval.modelKey,
                specification: .init(allowedTools: approval.allowedTools, completionGates: approval.completionGates),
                authorizationScope: .init(canonicalRoots: [project], writableRoots: [], allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 49, count: 32))
            let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: taskID, capabilityID: credential.capabilityID,
                projectID: projectID, projectGeneration: .initial, approval: approval, verifierSHA256: credential.verifier.sha256,
                expiresAt: ISO8601.string(from: Date().addingTimeInterval(3_600)))
            _ = try await repository.prepareNativeContinuityTask(request: request, approvedAssignment: assignment)
            // Native source execution remains explicit even when automatic handoff is disabled.
            let previousPolicy = try app.config.budgetPolicySelection(scope: .globalDefault)
            _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: previousPolicy.revision,
                expectedGlobalRevision: previousPolicy.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
            let managerID = UUID()
            let bridge = MCPTaskHTTPService { credential, token in
                let attached = try await repository.authenticateNativeTaskCapability(credential: credential, cancellation: token)
                return try MCPNativeTaskSourceDispatcher(app: app, attachment: attached, managerInstanceID: managerID)
            }
            bridge.listenerStarted(epoch: UUID()); bridge.setOperational(true)
            return try SourceOwnerFixture(app: app, projectID: projectID, taskID: taskID, credential: credential,
                assignment: assignment, provider: SourceOwnerProvider(mode: mode,
                    path: project.appendingPathComponent("source.txt").path, contextLength: contextLength), bridge: bridge)
        } catch { app.shutdown(); try? FileManager.default.removeItem(at: home); throw error }
    }
    func service() -> NativeSourceConversationService {
        let service = NativeSourceConversationService(repository: repository, providerWorkAdmission: pool, managerInstanceID: UUID(), clock: SystemClock(),
            attachmentResolver: { [credential, taskID] requested in
                guard requested == taskID else { throw NativeSourceConversationError.notFound }
                return .init(endpoint: URL(string: "http://127.0.0.1:8765/mcp/continuity")!, credential: credential, sourceSessionID: UUID())
            }, providerResolver: { [provider] _ in provider }, configurationResolver: {
                .init(revision: "fixture-revision", endpoint: "http://127.0.0.1:1234", modelKey: "fixture/native", credentialConfigured: false, saved: true)
            }, policyResolver: { [app] project, generation in
                try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride, projectID: project.description, projectGeneration: Int(generation.rawValue)))
            }, tools: { [bridge] credential, lease, token in try await bridge.nativeProviderTools(credential: credential, lease: lease, cancellation: token) },
            call: { [bridge, budgetDiagnostics] credential, reference, lease, budget, token in
                do {
                    let output = try await bridge.submitNativeCall(credential: credential, reference: reference,
                        lease: lease, outputBudget: budget, cancellation: token)
                    if output.readyHandoffCommitted {
                        let payload = try JSONSupport.object(from: output.canonicalPayloadJSON)
                        budgetDiagnostics.record(handoffID: payload["handoff_id"] as? String)
                    }
                    return output
                } catch {
                    budgetDiagnostics.record(error: error as? NativeSourceConversationError)
                    throw error
                }
            }, budgetEvaluator: { prepared, preflight, capabilities, selection in
                try NativeSourceBudgetEvaluator.providerApproval(prepared: prepared, preflight: preflight,
                    capabilities: capabilities, policySelection: selection)
            }, outputBudgetEvaluator: { [budgetDiagnostics] call, outputs, preflight, capabilities, selection in
                let budget = try NativeSourceBudgetEvaluator.outputBudget(call: call, priorOutputs: outputs,
                    emptyOutputPreflight: preflight, capabilities: capabilities, policySelection: selection)
                if call.toolName == "fs_read" {
                    let ceiling = min(65_536, call.attachment.sourceLimits.maximumResultBytes,
                        call.attachment.setup.record.assignment.authorizationScope.maximumInlineOutputBytes,
                        selection.policy.tools.maxResultBytes, call.prepared.frozenCeilings?.tools.maxResultBytes ?? Int.max)
                    budgetDiagnostics.record(read: .init(contextLength: capabilities.contextLength,
                        approvedResultBytes: ceiling, requiredEscapedBytes: ceiling * CanonicalToolResultOutputBounds.maximumStringExpansion,
                        maximumCanonicalToolResultBytes: budget.maximumCanonicalToolResultBytes,
                        maximumEscapedPayloadBytes: budget.maximumEscapedPayloadBytes))
                }
                return budget
            },
            beginProviderOperation: { [operations] in operations.increment(); return .init { operations.decrement() } })
        servicesLock.lock(); services.append(service); servicesLock.unlock()
        return service
    }
    func scalar(_ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            throw NativeSourceConversationError.integrityFailure
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeSourceConversationError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NativeSourceConversationError.integrityFailure }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func currentServices() -> [NativeSourceConversationService] {
        servicesLock.lock(); defer { servicesLock.unlock() }; return services
    }
    func close() async {
        await provider.release()
        for service in currentServices() { _ = await service.shutdown(deadline: Date().addingTimeInterval(5)) }
        _ = await bridge.shutdown()
        app.shutdown(); try? FileManager.default.removeItem(at: app.paths.home)
    }
}

private final class SourceOwnerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
}

private final class SourceOwnerBudgetDiagnostics: @unchecked Sendable {
    struct Read: Sendable {
        let contextLength: Int
        let approvedResultBytes: Int
        let requiredEscapedBytes: Int
        let maximumCanonicalToolResultBytes: Int
        let maximumEscapedPayloadBytes: Int
    }
    struct Snapshot: Sendable {
        let read: Read?
        let bridgeError: NativeSourceConversationError?
        let handoffID: String?
    }
    private let lock = NSLock()
    private var lastRead: Read?
    private var lastError: NativeSourceConversationError?
    private var lastHandoffID: String?
    func record(handoffID: String?) { lock.lock(); lastHandoffID = handoffID; lock.unlock() }
    func record(read: Read) { lock.lock(); lastRead = read; lock.unlock() }
    func record(error: NativeSourceConversationError?) { lock.lock(); lastError = error; lock.unlock() }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(read: lastRead, bridgeError: lastError, handoffID: lastHandoffID)
    }
}

actor SourceOwnerProvider: ManagedModelProviderObservedDispatching {
    enum Mode: Sendable { case heldProbe, unknownRoot, readHandoffSuffix, readThenAnswer, answer }
    struct Counts: Sendable { let probes: Int; let roots: Int; let continuations: Int; let lookups: Int; let legacyLookups: Int; let continuationPreflights: Int }
    nonisolated let providerID = "lmstudio"
    private let mode: Mode
    private let path: String
    private let contextLength: Int
    private var probes = 0, roots = 0, continuations = 0, lookups = 0, legacyLookups = 0, continuationPreflights = 0
    private var hold: CheckedContinuation<Void, Never>?
    private var released = false
    private var lookupAllowed = false
    private var retained: ProviderTurn?
    private var lastInput: Data?
    init(mode: Mode, path: String, contextLength: Int = 131_072) {
        self.mode = mode; self.path = path; self.contextLength = contextLength
    }
    func counts() -> Counts { .init(probes: probes, roots: roots, continuations: continuations, lookups: lookups, legacyLookups: legacyLookups, continuationPreflights: continuationPreflights) }
    func continuationInput() -> Data? { lastInput }
    func release() { released = true; hold?.resume(); hold = nil }
    func allowRecordedLookup() { lookupAllowed = true }
    func probe() async throws -> ProviderCapabilities {
        probes += 1
        if mode == .heldProbe, !released { await withCheckedContinuation { hold = $0 } }
        return try capabilities()
    }
    private func capabilities() throws -> ProviderCapabilities {
        try .init(providerID: providerID, providerVersion: "fixture", modelKey: "fixture/native", providerInstanceID: "fixture-instance",
            contextLength: contextLength, maximumContextLength: contextLength, statefulResponses: true, streaming: false,
            customTools: true, mcp: false, structuredOutput: false, usageReporting: false, idempotencyLookup: false,
            capabilityFingerprintSHA256: String(repeating: "b", count: 64))
    }
    private func limits() throws -> ProviderExecutionLimits {
        try .init(maximumOutputTokens: 4_096, maximumRequestBytes: 524_288, maximumResponseBytes: 2_097_152,
            maximumTextBytes: 524_288, maximumToolArgumentBytes: 262_144, maximumJSONBytes: 2_097_152,
            maximumSSELineBytes: 262_144, maximumSSEEventBytes: 1_048_576,
            connectTimeoutSeconds: 5, firstByteTimeoutSeconds: 30, idleTimeoutSeconds: 30, totalTimeoutSeconds: 120)
    }
    private func preflight(kind: ProviderRequestPreflight.Kind, bytes: Data, inputBytes: Int? = nil) throws -> ProviderRequestPreflight {
        try .init(kind: kind, modelKey: "fixture/native", configurationRevision: "fixture-revision",
            configurationFingerprintSHA256: String(repeating: "a", count: 64), limits: limits(),
            bodySHA256: JSONSupport.sha256Hex(bytes), bodyByteCount: bytes.count, serializedInputByteCount: inputBytes)
    }
    func preflightRoot(_ request: ProviderRootRequest) async throws -> ProviderRequestPreflight {
        try preflight(kind: .root, bytes: ForgeJSONCanonicalizationV1.data(from: ["model": request.modelKey,
            "input": request.input, "tools": request.tools.map { try JSONSerialization.jsonObject(with: $0) }]))
    }
    func preflightContinuation(_ request: ProviderContinuationRequest) async throws -> ProviderRequestPreflight {
        continuationPreflights += 1
        return try preflight(kind: .continuation, bytes: ForgeJSONCanonicalizationV1.data(from: ["model": request.modelKey,
            "previous_response_id": request.previousResponseID, "input": JSONSerialization.jsonObject(with: request.input),
            "tools": request.tools.map { try JSONSerialization.jsonObject(with: $0) }]),
            inputBytes: ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: request.input)).count)
    }
    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn { throw NativeSourceConversationError.unsupportedProvider }
    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn { throw NativeSourceConversationError.unsupportedProvider }
    func createRoot(_ request: ProviderRootRequest, observedCapabilities: ProviderCapabilities) async throws -> ProviderTurn {
        guard observedCapabilities == (try capabilities()) else { throw NativeSourceConversationError.conflict }
        roots += 1
        var calls: [ProviderToolCall] = []
        if mode == .readHandoffSuffix || mode == .readThenAnswer {
            calls.append(try .init(itemID: "item-read", callID: "source-read", name: "fs_read", argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["path": path])))
        }
        if mode == .readHandoffSuffix {
            calls.append(try .init(itemID: "item-handoff", callID: "source-handoff", name: "session_handoff",
                argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["goal": "Continue the approved assignment", "summary": "actual read observed", "next_actions": ["Continue the approved assignment"]])))
            calls.append(try .init(itemID: "item-late", callID: "source-late", name: "fs_read", argumentsJSON: ForgeJSONCanonicalizationV1.data(from: ["path": path])))
        }
        let turn = try result(operation: request.operationID, parent: nil, calls: calls)
        retained = turn
        if mode == .unknownRoot { throw URLError(.networkConnectionLost) }
        return turn
    }
    func continueSession(_ request: ProviderContinuationRequest, observedCapabilities: ProviderCapabilities) async throws -> ProviderTurn {
        guard observedCapabilities == (try capabilities()) else { throw NativeSourceConversationError.conflict }
        continuations += 1; lastInput = request.input
        let turn = try result(operation: request.operationID, parent: request.previousResponseID, calls: [])
        retained = turn; return turn
    }
    private func result(operation: UUID, parent: String?, calls: [ProviderToolCall]) throws -> ProviderTurn {
        try .init(requestID: operation.uuidString.lowercased(), responseID: "response-" + operation.uuidString.lowercased(), previousResponseID: parent,
            providerID: providerID, providerVersion: "fixture", modelKey: "fixture/native", providerInstanceID: "fixture-instance",
            messages: calls.isEmpty ? ["Retained actual response"] : [], toolCalls: calls, usage: nil, completed: true,
            finishReason: calls.isEmpty ? .stop : .toolCalls)
    }
    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { legacyLookups += 1; throw NativeSourceConversationError.unsupportedProvider }
    func lookupRecorded(idempotencyKey: String) async throws -> ProviderTurn? { lookups += 1; return lookupAllowed ? retained : nil }
    func cancel(requestID: String) async { }
}

private enum NativeSourceGateRejectedCommand: CaseIterable { case removed, cancelled, expired, nonOperational, closed }

/// Actor inheritance gives the fixture the same synchronous bind-before-execution
/// boundary as the production owner, without adding a service checkpoint hook.
private actor NativeSourceGateLaunchFixture {
    struct Launch: Sendable {
        let admitted: Bool
        let workID: UUID
        let cancellation: ToolCallCancellation
        let task: Task<Void, Never>
    }
    private var started = 0, completed = 0, cancelled = 0
    func launch(gate: NativeSourceOperationGate, commandID: UUID, hold: Bool = false) -> Launch {
        let workID = UUID(), token = ToolCallCancellation()
        let task = Task { [self] in
            do {
                try Task.checkCancellation(); try token.checkCancellation()
                started += 1
                if hold { try await Task.sleep(for: .seconds(5)) }
                try Task.checkCancellation(); try token.checkCancellation()
                completed += 1
            } catch { cancelled += 1 }
        }
        let admitted = gate.bind(workID, originatingCommandID: commandID, cancellation: token, task: task)
        return .init(admitted: admitted, workID: workID, cancellation: token, task: task)
    }
    func counts() -> (started: Int, completed: Int, cancelled: Int) { (started, completed, cancelled) }
}

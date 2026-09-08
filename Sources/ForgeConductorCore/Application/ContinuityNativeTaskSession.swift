import Foundation

/// A native owner retains one exact task correlation. This type has no wire
/// decoder, global registry or implicit selection by client, project or cwd.
final class ContinuityNativeTaskSession: Sendable {
    let app: ForgeApp
    let clientID: ClientID
    private let setup: AuthorizedContinuityTaskSetup
    private let context: ToolInvocationContext
    private let owner: ProjectBindingOwner

    private init(app: ForgeApp, setup: AuthorizedContinuityTaskSetup,
                 context: ToolInvocationContext, owner: ProjectBindingOwner) {
        self.app = app
        self.setup = setup
        self.context = context
        self.owner = owner
        clientID = context.clientID
    }

    /// Called from authenticated native assignment setup, never a model request.
    static func enroll(app: ForgeApp, taskID: UUID = UUID(),
        approvedAssignment: ContinuityTaskAssignment, callerContext: ToolInvocationContext,
        callerOwner: ProjectBindingOwner, cancellation: ToolCallCancellation? = nil
    ) async throws -> ContinuityNativeTaskSession {
        let setup = try await app.projectContexts.repository.authorizeContinuityTask(
            taskID: taskID, projectID: callerContext.projectID,
            expectedGeneration: callerContext.projectGeneration, approvedAssignment: approvedAssignment,
            callerContext: callerContext, callerOwner: callerOwner, cancellation: cancellation)
        return Self(app: app, setup: setup, context: callerContext, owner: callerOwner)
    }

    /// Authenticated native attachment to an exact persisted task. Reattachment
    /// restores control access without reopening a transferred source for writes.
    static func reattach(app: ForgeApp, taskID: UUID,
        callerContext: ToolInvocationContext, callerOwner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) async throws -> ContinuityNativeTaskSession {
        let setup = try await app.projectContexts.repository.reattachContinuityTask(
            taskID: taskID, projectID: callerContext.projectID,
            expectedGeneration: callerContext.projectGeneration, callerContext: callerContext,
            callerOwner: callerOwner, cancellation: cancellation)
        return Self(app: app, setup: setup, context: callerContext, owner: callerOwner)
    }

    func handles(_ name: String) -> Bool {
        ContinuityControlToolName(rawValue: name) != nil
            || name == "session_checkpoint" || name == "session_handoff"
    }

    /// The existing MCP worker calls this bounded bridge. UI owners use call().
    func callSynchronously(name: String, arguments: [String: Any],
        role: ContinuityControlCapabilities.Role, connected: Bool?, cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        do {
            let serialized = try SerializedToolArguments(arguments)
            return try app.projectContexts.performContinuityTaskOperation(cancellation: cancellation) { control in
                try await self.call(name: name, arguments: serialized.decoded(), role: role,
                    connected: connected, cancellation: control)
            }
        } catch {
            return try ContinuityControlToolResponse.failure(.mapping(error)).toolResult()
        }
    }

    func call(name: String, arguments: [String: Any],
        role: ContinuityControlCapabilities.Role = .primary, connected: Bool? = nil,
        cancellation: ToolCallCancellation? = nil
    ) async throws -> ToolResult {
        let control = cancellation ?? ToolCallCancellation(timeoutSeconds: ToolRouter.defaultCallTimeoutSeconds)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                return try await execute(name: name, arguments: arguments, role: role,
                    connected: connected, cancellation: control)
            } catch {
                return try ContinuityControlToolResponse.failure(.mapping(error)).toolResult()
            }
        } onCancel: {
            control.cancel()
        }
    }

    private func execute(name: String, arguments: [String: Any],
        role: ContinuityControlCapabilities.Role, connected: Bool?, cancellation: ToolCallCancellation
    ) async throws -> ToolResult {
        do {
            try cancellation.checkCancellation()
            let result: ToolResult
            if name == "session_checkpoint" || name == "session_handoff" {
                result = try await commit(arguments: arguments, finalize: name == "session_handoff",
                    cancellation: cancellation)
            } else {
                let request = try ContinuityControlToolRequest(name: name, arguments: arguments)
                let response: ContinuityControlToolResponse
                switch request {
                case .capabilities:
                    response = .capabilities(try await capabilities(role: role, connected: connected,
                        cancellation: cancellation))
                case .start(let request):
                    response = .started(try await app.continuity.submitAuthorizedHandoff(request,
                        taskID: setup.correlation.taskID, correlation: setup.correlation, context: context,
                        owner: owner, repository: app.projectContexts.repository, config: app.config,
                        cancellation: cancellation))
                case .status(let operationID):
                    let engine = app.continuityControl.coordinator.engine
                    let source = app.continuity
                    let snapshot = try await app.projectContexts.repository.continuityOperationStatus(
                        operationID: operationID, taskID: setup.correlation.taskID, correlation: setup.correlation,
                        context: context, owner: owner, cancellation: cancellation) { acceptance in
                            try source.authorizedOperationProgress(acceptance: acceptance, engine: engine,
                                cancellation: cancellation)
                        }
                    response = .status(try Self.wireStatus(snapshot))
                case .cancel(let operationID):
                    let cancelled = try await app.projectContexts.repository.requestContinuityOperationCancellation(
                        operationID: operationID, taskID: setup.correlation.taskID, correlation: setup.correlation,
                        context: context, owner: owner, cancellation: cancellation)
                    guard let disposition = ContinuityControlToolResponse.CancelDisposition(rawValue: cancelled.disposition.rawValue) else {
                        throw ContinuityControlToolFailure(.integrityFailure)
                    }
                    response = .cancelled(disposition: disposition, operation: try Self.wireStatus(cancelled.snapshot))
                }
                result = try response.toolResult()
            }
            cancellation.promoteCommittedResultIfPresent(result)
            return result
        } catch {
            return try ContinuityControlToolResponse.failure(.mapping(error)).toolResult()
        }
    }

    private func commit(arguments: [String: Any], finalize: Bool,
                        cancellation: ToolCallCancellation?) async throws -> ToolResult {
        let serialized = try SerializedToolArguments(arguments)
        let selection = try policySelection()
        let source = app.continuity
        let clientID = clientID
        let committed = try await app.projectContexts.repository.withAuthorizedContinuityTask(
            taskID: setup.correlation.taskID, correlation: setup.correlation, context: context,
            owner: owner, cancellation: cancellation) { authorization in
                try source.commitAuthorizedHandoff(arguments: serialized.decoded(), clientID: clientID,
                    source: .model, finalize: finalize, authorization: authorization,
                    automaticHandoffEnabled: selection.policy.automaticHandoffEnabled, cancellation: cancellation)
            }
        return .success(try source.authorizedCommitPayload(committed, finalize: finalize))
    }

    private func capabilities(role: ContinuityControlCapabilities.Role, connected: Bool?,
                              cancellation: ToolCallCancellation?) async throws -> ContinuityControlCapabilities {
        let record = try await app.projectContexts.repository.validateContinuityOperationControlAuthority(
            taskID: setup.correlation.taskID, correlation: setup.correlation, context: context,
            owner: owner, cancellation: cancellation)
        let selection = try policySelection()
        // Native identity is verified here; deployment and provider readiness
        // require independent matching observations, not an assignment string.
        return .init(deployed: nil, connected: connected, ready: false,
            automaticHandoffEnabled: selection.policy.automaticHandoffEnabled, exactIDSupport: true,
            providerMode: record.assignment.providerID == "lmstudio" ? .nativeLMStudioResponses : .unavailable,
            taskIdentity: .verifiedNativeTask, role: role, deploymentID: nil, buildVersion: ForgeApp.version,
            qualification: .init(nativeAPI: .unqualified, desktopNewChat: .notObserved,
                guiClosedRecovery: .notObserved, laterRollover: .notObserved),
            reasons: ["deployment_not_observed", "provider_not_observed"])
    }

    private func policySelection() throws -> BudgetPolicySelection {
        guard let generation = Int(exactly: context.projectGeneration.rawValue) else {
            throw ContinuityControlToolFailure(.staleGeneration)
        }
        return try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: context.projectID.description, projectGeneration: generation))
    }

    private static func wireStatus(_ snapshot: ContinuityOperationStatus) throws -> ContinuityControlOperationStatus {
        guard let state = ContinuityControlOperationStatus.State(rawValue: snapshot.state.rawValue),
              let recovery = ContinuityControlOperationStatus.Recovery.State(rawValue: snapshot.recoveryState.rawValue) else {
            throw ContinuityControlToolFailure(.integrityFailure)
        }
        let terminal = try snapshot.terminalReceipt.map { receipt in
            guard let outcome = ContinuityControlOperationStatus.TerminalReceipt.Outcome(rawValue: receipt.outcome.rawValue) else {
                throw ContinuityControlToolFailure(.integrityFailure)
            }
            return ContinuityControlOperationStatus.TerminalReceipt(outcome: outcome,
                receiptSHA256: receipt.receiptSHA256, recordedAt: receipt.recordedAt)
        }
        return .init(operationID: snapshot.acceptance.operationID, runID: snapshot.acceptance.runID,
            source: snapshot.acceptance.sourceIdentity, state: state,
            deliveryState: .init(source: snapshot.deliveryState),
            recovery: .init(state: recovery, reasonCode: snapshot.reasonCode, retryAt: snapshot.retryAt),
            terminalReceipt: terminal)
    }
}

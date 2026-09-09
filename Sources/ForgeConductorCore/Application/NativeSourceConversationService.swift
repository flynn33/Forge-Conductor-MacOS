import Foundation

/// A manager operation is retained through the actual exit of provider work.
/// Finishing a repeated or late callback cannot release a different operation.
final class NativeSourceProviderOperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    init(finish: @escaping @Sendable () -> Void) { completion = finish }
    func finish() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

struct NativeSourceShutdownReport: Sendable {
    let completed: Bool
    let activeTaskIDs: [UUID]
    let pendingCommandCount: Int
}
struct NativeSourceRecoveryReport: Sendable {
    let scanned: Int
    let started: Int
    let retained: Int
}

struct NativeSourcePressureIO: Sendable {
    let checkpoint: @Sendable (ResolvedNativeSourceProviderCall, ToolCallCancellation) throws -> (prepared: PreparedContinuitySourceCommit, resultJSON: Data)
    let preflight: @Sendable (PreparedContinuitySourceCommit) throws -> Data
    let read: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, ToolCallCancellation) throws -> ContinuityHandoffCommit?
    let commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool, ToolCallCancellation) throws -> ContinuityHandoffCommit

    init(source: ContextContinuityService,
        commitOverride: (@Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool, ToolCallCancellation) throws -> ContinuityHandoffCommit)? = nil) {
        checkpoint = { call, token in
            let prepared = try source.prepareAuthorizedSourceCommit(arguments: JSONSupport.object(from: call.canonicalArgumentsJSON),
                clientID: call.attachment.context.clientID, source: .model, finalize: false,
                authorization: call.attachment.setup.record.authorization, cancellation: token)
            let result = try source.nativeSourcePreparedToolResult(prepared)
            return (prepared, try ForgeJSONCanonicalizationV1.data(from: ["ok":result.ok,"is_error":result.isError,"payload":result.payload]))
        }
        preflight = { try MCPToolResponse.data(id: String(repeating: "\u{0}", count: 256), result: source.nativeSourcePreparedToolResult($0)) }
        read = { try source.readPreparedSourceCommitForReconciliation($0, authorization: $1, cancellation: $2) }
        commit = commitOverride ?? { try source.commitPreparedAuthorizedSourceCommit($0, authorization: $1, automaticHandoffEnabled: $2, cancellation: $3) }
    }
}

/// The manager's existing watchdog calls recovery. This owner has no dispatch
/// queue and shares the same provider ceiling as managed run coordinators.
actor NativeSourceConversationService {
    typealias Tools = @Sendable (NativeTaskCapabilityCredential, NativeSourceConversationLease, ToolCallCancellation) async throws -> [Data]
    typealias Call = @Sendable (NativeTaskCapabilityCredential, NativeSourceProviderCallReference, NativeSourceConversationLease, NativeSourceProviderOutputBudget, PreparedContinuitySourceCommit?, ToolCallCancellation) async throws -> NativeSourceProviderCallOutput
    typealias OutputObserver = @Sendable (ResolvedNativeSourceProviderCall, NativeSourceToolOutputEvaluation) -> Void

    private struct Key: Hashable, Sendable { let taskID: UUID; let requestID: UUID }
    private struct Work {
        let ownerID: UUID
        let cancellation: ToolCallCancellation
        let task: Task<Void, Never>
    }
    private struct Admission {
        let ownerID: UUID
        let cancellation: ToolCallCancellation
    }
    private let repository: ProjectControlPlaneRepository
    private let providerWorkAdmission: NativeProviderWorkAdmission
    private let managerInstanceID: UUID
    private let clock: any Clock
    private let attachmentResolver: @Sendable (UUID) throws -> NativeTaskHTTPAttachment
    private let providerResolver: @Sendable (ContinuityTaskAssignment) throws -> any ManagedModelProviderRequestPreflighting
    private let configurationResolver: @Sendable () async throws -> ProviderConfigurationSnapshot
    private let policyResolver: @Sendable (ProjectID, ProjectGeneration) throws -> BudgetPolicySelection
    private let tools: Tools
    private let call: Call
    private let pressureIO: NativeSourcePressureIO
    private let outputObserver: OutputObserver
    private let beginProviderOperation: @Sendable () throws -> NativeSourceProviderOperationLease
    private nonisolated let operationGate = NativeSourceOperationGate()
    private var operational: Bool { operationGate.isOperational }
    private var closing = false
    private var commands: [UUID: ToolCallCancellation] = [:]
    private var admissions: [Key: Admission] = [:]
    private var work: [Key: Work] = [:]
    private var recoveryInProgress = false
    private var recoveryCursor: Int64?
    private var pressureCursor: Int64?
    private var receiptCursor: Int64?

    init(repository: ProjectControlPlaneRepository, providerWorkAdmission: NativeProviderWorkAdmission,
         managerInstanceID: UUID, clock: any Clock,
         attachmentResolver: @escaping @Sendable (UUID) throws -> NativeTaskHTTPAttachment,
         providerResolver: @escaping @Sendable (ContinuityTaskAssignment) throws -> any ManagedModelProviderRequestPreflighting,
         configurationResolver: @escaping @Sendable () async throws -> ProviderConfigurationSnapshot,
         policyResolver: @escaping @Sendable (ProjectID, ProjectGeneration) throws -> BudgetPolicySelection,
         tools: @escaping Tools, call: @escaping Call,
         pressureIO: NativeSourcePressureIO, outputObserver: @escaping OutputObserver = { _, _ in },
         beginProviderOperation: @escaping @Sendable () throws -> NativeSourceProviderOperationLease) {
        self.repository = repository; self.providerWorkAdmission = providerWorkAdmission
        self.managerInstanceID = managerInstanceID; self.clock = clock
        self.attachmentResolver = attachmentResolver; self.providerResolver = providerResolver
        self.configurationResolver = configurationResolver; self.policyResolver = policyResolver
        self.tools = tools; self.call = call; self.pressureIO = pressureIO
        self.outputObserver = outputObserver; self.beginProviderOperation = beginProviderOperation
    }

    func send(_ request: NativeSourceSendRequest, cancellation: ToolCallCancellation) async throws -> NativeSourceOperatorResponse {
        let commandID = try beginCommand(cancellation)
        defer { commands.removeValue(forKey: commandID); operationGate.remove(commandID) }
        let attachment = try attachmentResolver(request.taskID)
        let credential = attachment.credential
        if let prior = try await repository.nativeSourceRequest(taskID: request.taskID, requestID: request.requestID,
            expectedUserInput: request.input, credential: credential, cancellation: cancellation) {
            return try await response(prior, credential: credential, disposition: "replayed", cancellation: cancellation)
        }
        let key = Key(taskID: request.taskID, requestID: request.requestID)
        let ownerID = try reserveAdmission(key, cancellation: cancellation)
        defer { if admissions[key]?.ownerID == ownerID { admissions.removeValue(forKey: key) } }
        guard let permit = providerWorkAdmission.tryAcquire(owner: .source(taskID: request.taskID, requestID: request.requestID)) else {
            throw NativeSourceConversationError.capacityExceeded
        }
        var transferred = false
        defer { if !transferred { providerWorkAdmission.release(permit) } }
        let operationLease = try beginProviderOperation()
        defer { if !transferred { operationLease.finish() } }
        var sourceLease: NativeSourceConversationLease?
        do {
            let authenticated = try await repository.authenticateNativeTaskCapability(credential: credential, cancellation: cancellation)
            guard authenticated.descriptor.taskID == request.taskID else { throw NativeSourceConversationError.notFound }
            try checkAdmission(key, ownerID: ownerID, cancellation: cancellation)
            let assignment = authenticated.setup.record.assignment
            let provider = try observedProvider(assignment)
            _ = try await checkedConfiguration(assignment: assignment, preflight: nil)
            let policy = try policyResolver(authenticated.descriptor.projectID, authenticated.descriptor.projectGeneration)
            let conversation = try await repository.enrollNativeSourceConversation(requestID: request.requestID,
                taskID: request.taskID, credential: credential, policySelection: policy, cancellation: cancellation)
            let lease = try await repository.acquireNativeSourceConversationLease(conversationID: conversation.conversationID,
                credential: credential, managerInstanceID: managerInstanceID, cancellation: cancellation)
            sourceLease = lease
            try checkAdmission(key, ownerID: ownerID, cancellation: cancellation)
            let definitions = try await tools(credential, lease, cancellation)
            let prepared = try await repository.prepareNativeSourceProviderTurn(request: .init(requestID: request.requestID,
                conversationID: conversation.conversationID, userInput: request.input), credential: credential,
                lease: lease, tools: definitions, cancellation: cancellation)
            try checkAdmission(key, ownerID: ownerID, cancellation: cancellation)
            let projection = try await response(prepared, credential: credential, disposition: "accepted", cancellation: cancellation)
            try checkAdmission(key, ownerID: ownerID, cancellation: cancellation)
            let launched = launch(key: key, ownerID: ownerID, originatingCommandID: commandID,
                prepared: prepared, credential: credential, lease: lease,
                assignment: assignment, provider: provider, permit: permit, operationLease: operationLease)
            // The retained worker owns cleanup even when a concurrent stop rejects its binding.
            transferred = true
            sourceLease = nil
            guard launched else { throw NativeSourceOperatorError.unavailable }
            return projection
        } catch {
            if let sourceLease { try? await repository.releaseNativeSourceConversationLease(lease: sourceLease) }
            throw error
        }
    }

    func status(_ request: NativeSourceStatusRequest, cancellation: ToolCallCancellation) async throws -> NativeSourceOperatorResponse {
        let commandID = try beginCommand(cancellation, requiresOperational: false)
        defer { commands.removeValue(forKey: commandID); operationGate.remove(commandID) }
        let credential = try attachmentResolver(request.taskID).credential
        guard let prepared = try await repository.nativeSourceRequest(taskID: request.taskID, requestID: request.requestID,
            credential: credential, cancellation: cancellation) else { throw NativeSourceConversationError.notFound }
        return try await response(prepared, credential: credential, disposition: "observed", cancellation: cancellation)
    }

    func cancel(_ request: NativeSourceCancelRequest, cancellation: ToolCallCancellation) async throws -> NativeSourceOperatorResponse {
        let commandID = try beginCommand(cancellation, requiresOperational: false)
        defer { commands.removeValue(forKey: commandID); operationGate.remove(commandID) }
        let credential = try attachmentResolver(request.taskID).credential
        guard let prepared = try await repository.nativeSourceRequest(taskID: request.taskID, requestID: request.requestID,
            credential: credential, cancellation: cancellation) else { throw NativeSourceConversationError.notFound }
        _ = try await repository.requestNativeSourceConversationCancellation(conversationID: prepared.conversationID,
            requestID: request.requestID, cancelRequestID: request.cancelRequestID, reason: request.reason,
            credential: credential, cancellation: cancellation)
        let key = Key(taskID: request.taskID, requestID: request.requestID)
        admissions[key]?.cancellation.cancel()
        work[key]?.cancellation.cancel()
        work[key]?.task.cancel()
        guard let current = try await repository.nativeSourceRequest(taskID: request.taskID, requestID: request.requestID,
            credential: credential, cancellation: cancellation) else { throw NativeSourceConversationError.notFound }
        return try await response(current, credential: credential, disposition: "cancel_requested", cancellation: cancellation)
    }

    func recoverOnce(cancellation: ToolCallCancellation) async throws -> NativeSourceRecoveryReport {
        guard operational, !closing, !recoveryInProgress else { return .init(scanned: 0, started: 0, retained: work.count) }
        let commandID = try beginCommand(cancellation)
        recoveryInProgress = true
        defer { recoveryInProgress = false; commands.removeValue(forKey: commandID); operationGate.remove(commandID) }
        let page = try await repository.pendingNativeSourceTurns(afterRowID: recoveryCursor, limit: 4, cancellation: cancellation)
        recoveryCursor = page.nextRowID
        var started = 0
        for reference in page.references {
            try cancellation.checkCancellation()
            guard operational, !closing else { break }
            let key = Key(taskID: reference.taskID, requestID: reference.requestID)
            do {
                let ownerID = try reserveAdmission(key, cancellation: cancellation)
                defer { if admissions[key]?.ownerID == ownerID { admissions.removeValue(forKey: key) } }
                guard let permit = providerWorkAdmission.tryAcquire(owner: .source(taskID: key.taskID, requestID: key.requestID)) else { continue }
                var transferred = false
                defer { if !transferred { providerWorkAdmission.release(permit) } }
                let operationLease = try beginProviderOperation()
                defer { if !transferred { operationLease.finish() } }
                let credential = try attachmentResolver(key.taskID).credential
                var lease: NativeSourceConversationLease?
                do {
                    let acquired = try await repository.acquireNativeSourceConversationLease(conversationID: reference.conversationID,
                        credential: credential, managerInstanceID: managerInstanceID, cancellation: cancellation)
                    lease = acquired
                    let authenticated = try await repository.validateNativeSourceConversationLease(lease: acquired,
                        credential: credential, cancellation: cancellation)
                    let prepared = try await repository.nativeSourcePreparedTurn(stageID: reference.stageID,
                        credential: credential, lease: acquired, cancellation: cancellation)
                    guard prepared.taskID == key.taskID, prepared.requestID == key.requestID else { throw NativeSourceConversationError.conflict }
                    let assignment = authenticated.setup.record.assignment
                    let provider = try observedProvider(assignment)
                    _ = try await checkedConfiguration(assignment: assignment, preflight: prepared.retainedPreflight)
                    try checkAdmission(key, ownerID: ownerID, cancellation: cancellation)
                    let launched = launch(key: key, ownerID: ownerID, originatingCommandID: commandID,
                        prepared: prepared, credential: credential, lease: acquired,
                        assignment: assignment, provider: provider, permit: permit, operationLease: operationLease)
                    transferred = true
                    lease = nil
                    guard launched else { throw NativeSourceOperatorError.unavailable }
                    started += 1
                } catch {
                    if let lease { try? await repository.releaseNativeSourceConversationLease(lease: lease) }
                    throw error
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* One stale, disabled or malformed reference does not block its peers. */ }
        }
        let pressure = try await repository.pendingNativeSourcePressureTurns(afterRowID: pressureCursor, limit: 4, cancellation: cancellation)
        pressureCursor = pressure.nextRowID
        for reference in pressure.references {
            try cancellation.checkCancellation()
            guard operational, !closing else { break }
            do {
                let credential = try attachmentResolver(reference.taskID).credential
                let claim = try await repository.acquireNativeSourcePressureClaim(conversationID: reference.conversationID,
                    stageID: reference.stageID, credential: credential, managerInstanceID: managerInstanceID, cancellation: cancellation)
                // Storage recovery owns no provider permit and sends no request.
                await storePressure(claim, credential: credential)
            } catch is CancellationError { throw CancellationError() }
            catch { /* Bounded pages revisit stale or temporarily unavailable claims. */ }
        }
        let receipts = try await repository.pendingNativeSourcePressureReceipts(afterRowID: receiptCursor, limit: 4, cancellation: cancellation)
        receiptCursor = receipts.count == 4 ? receipts.last?.rowID : nil
        let io = pressureIO
        for reference in receipts {
            try cancellation.checkCancellation()
            guard operational, !closing else { break }
            do {
                let claim = try await repository.acquireNativeSourcePressureReceiptClaim(reference: reference,
                    managerInstanceID: managerInstanceID, cancellation: cancellation)
                do {
                    _ = try await repository.reconcileNativeSourcePressureReceipt(claim: claim,
                        readExisting: { try io.read($0, $1, cancellation) }, cancellation: cancellation)
                } catch {
                    try? await repository.deferNativeSourcePressureReceiptRetry(claim)
                }
                _ = try? await repository.releaseNativeSourcePressureReceiptClaim(claim)
            } catch is CancellationError { throw CancellationError() }
            catch { /* Read-only cleanup must not prevent another task's recovery. */ }
        }
        return .init(scanned: page.references.count + pressure.references.count + receipts.count, started: started, retained: work.count)
    }

    nonisolated func setOperational(_ value: Bool) { operationGate.setOperational(value) }

    func shutdown(deadline: Date) async -> NativeSourceShutdownReport {
        closing = true; operationGate.close(); cancelOwners()
        let remaining = min(15, max(0, deadline.timeIntervalSince(clock.now())))
        let end = ContinuousClock.now.advanced(by: .seconds(remaining))
        while hasRetainedWork(), ContinuousClock.now < end {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        return .init(completed: !hasRetainedWork(), activeTaskIDs: Set(work.keys.map(\.taskID)).sorted { $0.uuidString < $1.uuidString },
            pendingCommandCount: commands.count)
    }

    func hasRetainedWork() -> Bool { !work.isEmpty || !admissions.isEmpty || !commands.isEmpty || recoveryInProgress }

    private func beginCommand(_ token: ToolCallCancellation, requiresOperational: Bool = true) throws -> UUID {
        try token.checkCancellation()
        guard !closing, !requiresOperational || operational else { throw NativeSourceOperatorError.unavailable }
        guard commands.count < 8 else { throw NativeSourceConversationError.capacityExceeded }
        let id = UUID()
        guard operationGate.register(id, cancellation: token, requiresOperational: requiresOperational) else {
            throw NativeSourceOperatorError.unavailable
        }
        commands[id] = token; return id
    }
    private func reserveAdmission(_ key: Key, cancellation: ToolCallCancellation) throws -> UUID {
        try cancellation.checkCancellation()
        guard operational, !closing else { throw NativeSourceOperatorError.unavailable }
        guard work.count + admissions.count < 2,
              !work.keys.contains(where: { $0.taskID == key.taskID }),
              !admissions.keys.contains(where: { $0.taskID == key.taskID }) else { throw NativeSourceConversationError.capacityExceeded }
        let id = UUID(); admissions[key] = .init(ownerID: id, cancellation: cancellation); return id
    }
    private func checkAdmission(_ key: Key, ownerID: UUID, cancellation: ToolCallCancellation) throws {
        try Task.checkCancellation(); try cancellation.checkCancellation()
        guard operational, !closing, admissions[key]?.ownerID == ownerID else { throw NativeSourceOperatorError.unavailable }
    }
    private func cancelOwners() {
        for token in commands.values { token.cancel() }
        for admission in admissions.values { admission.cancellation.cancel() }
        for value in work.values { value.cancellation.cancel(); value.task.cancel() }
    }
    private func observedProvider(_ assignment: ContinuityTaskAssignment) throws -> any ManagedModelProviderObservedDispatching {
        let provider = try providerResolver(assignment)
        guard provider.providerID == assignment.providerID,
              let observed = provider as? any ManagedModelProviderObservedDispatching else { throw NativeSourceConversationError.unsupportedProvider }
        return observed
    }
    private func checkedConfiguration(assignment: ContinuityTaskAssignment, preflight: ProviderRequestPreflight?) async throws -> ProviderConfigurationSnapshot {
        let snapshot = try await configurationResolver()
        guard !snapshot.credentialCleanupPending,
              snapshot.modelKey.map({ $0 == assignment.modelKey }) ?? true,
              preflight.map({ $0.configurationRevision == snapshot.revision && $0.modelKey == assignment.modelKey }) ?? true else {
            throw NativeSourceConversationError.conflict
        }
        return snapshot
    }

    private func launch(key: Key, ownerID: UUID, originatingCommandID: UUID, prepared: NativeSourcePreparedTurn,
                        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
                        assignment: ContinuityTaskAssignment, provider: any ManagedModelProviderObservedDispatching,
                        permit: NativeProviderWorkPermit, operationLease: NativeSourceProviderOperationLease) -> Bool {
        let deadline = ISO8601DateFormatter().date(from: prepared.deadline) ?? clock.now()
        let token = ToolCallCancellation(timeoutSeconds: min(300, max(0, deadline.timeIntervalSince(clock.now()))))
        let leaseState = NativeSourceLeaseState(lease)
        let task = Task { [self] in
            await withTaskCancellationHandler {
                do {
                    if let pressure = try await protectedExchange(prepared: prepared, credential: credential, leaseState: leaseState,
                        assignment: assignment, provider: provider, cancellation: token) {
                        // The task group has joined inference and renewal. Storage
                        // owns a separate fixed deadline, with this task's stop fence.
                        await storePressure(pressure, credential: credential)
                    }
                } catch {
                    if !(error is CancellationError), !token.isCancelled,
                       let latest = try? await repository.nativeSourceRequest(taskID: key.taskID, requestID: key.requestID,
                           credential: credential, cancellation: ToolCallCancellation(timeoutSeconds: 3)),
                       latest.state == .prepared {
                        try? await repository.stopNativeSourcePreparedTurn(stageID: latest.stageID,
                            reasonCode: Self.stopReason(error), credential: credential, lease: await leaseState.current(),
                            cancellation: ToolCallCancellation(timeoutSeconds: 3))
                    }
                }
                let current = await leaseState.current()
                try? await repository.releaseNativeSourceConversationLease(lease: current)
                providerWorkAdmission.release(permit)
                operationLease.finish()
                finish(key, ownerID: ownerID)
            } onCancel: { token.cancel() }
        }
        work[key] = .init(ownerID: ownerID, cancellation: token, task: task)
        // This Task inherits the actor and cannot execute until this synchronous handover
        // returns. A rejected command therefore cancels it before any provider work starts.
        let launched = operationGate.bind(ownerID, originatingCommandID: originatingCommandID,
            cancellation: token, task: task)
        admissions.removeValue(forKey: key)
        return launched
    }
    private func finish(_ key: Key, ownerID: UUID) {
        guard work[key]?.ownerID == ownerID else { return }
        work.removeValue(forKey: key)
        operationGate.remove(ownerID)
    }

    private func protectedExchange(prepared: NativeSourcePreparedTurn, credential: NativeTaskCapabilityCredential,
        leaseState: NativeSourceLeaseState, assignment: ContinuityTaskAssignment,
        provider: any ManagedModelProviderObservedDispatching, cancellation: ToolCallCancellation) async throws -> NativeSourcePressureClaim? {
        try await withThrowingTaskGroup(of: NativeSourcePressureClaim?.self) { group in
            group.addTask { [self] in
                    try await exchange(prepared: prepared, credential: credential, leaseState: leaseState,
                    assignment: assignment, provider: provider, cancellation: cancellation)
            }
            group.addTask { [repository] in
                while true {
                    try await Task.sleep(for: .seconds(10))
                    try Task.checkCancellation(); try cancellation.checkCancellation()
                    let current = await leaseState.current()
                    let renewed = try await repository.renewNativeSourceConversationLease(lease: current,
                        credential: credential, cancellation: cancellation)
                    await leaseState.update(renewed)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, cancellation.remainingTimeInterval ?? 300)))
                cancellation.cancel()
                throw NativeSourceConversationError.deadlineExceeded
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func exchange(prepared initial: NativeSourcePreparedTurn, credential: NativeTaskCapabilityCredential,
        leaseState: NativeSourceLeaseState, assignment: ContinuityTaskAssignment,
        provider: any ManagedModelProviderObservedDispatching, cancellation: ToolCallCancellation) async throws -> NativeSourcePressureClaim? {
        var prepared = initial
        for _ in 0..<8 {
            try Task.checkCancellation(); try cancellation.checkCancellation()
            let lease = await leaseState.current()
            let authenticated = try await repository.validateNativeSourceConversationLease(lease: lease,
                credential: credential, cancellation: cancellation)
            guard authenticated.setup.record.assignment == assignment else { throw NativeSourceConversationError.conflict }
            let accepted: NativeSourceAcceptedProviderTurn
            switch prepared.state {
            case .submitted, .outcomeUnknown:
                let key = Self.idempotencyKey(prepared.request)
                guard let receipt = try await boundedLeg(cancellation: cancellation, operation: {
                    try await provider.lookupRecorded(idempotencyKey: key)
                }) else { throw NativeSourceConversationError.outcomeUnknown }
                accepted = try await repository.recoverNativeSourceAcceptedProviderTurn(stageID: prepared.stageID,
                    recoveredTurn: receipt, credential: credential, lease: await leaseState.current(), cancellation: cancellation)
            case .accepted:
                guard let retained = try await repository.nativeSourceAcceptedProviderTurn(stageID: prepared.stageID,
                    credential: credential, lease: lease, cancellation: cancellation) else { throw NativeSourceConversationError.integrityFailure }
                accepted = retained
            case .cancelledBeforeDispatch:
                return nil
            case .prepared:
                let preflight = try await Self.preflight(prepared.request, provider: provider)
                _ = try await checkedConfiguration(assignment: assignment, preflight: preflight)
                let definitions = try await tools(credential, await leaseState.current(), cancellation)
                guard definitions == Self.tools(prepared.request) else { throw NativeSourceConversationError.conflict }
                let check = try await repository.reserveNativeSourceCapabilityCheck(prepared: prepared, preflight: preflight,
                    credential: credential, lease: await leaseState.current(), cancellation: cancellation)
                let capabilities: ProviderCapabilities
                do {
                    capabilities = try await boundedLeg(cancellation: cancellation) { try await provider.probe() }
                    try await repository.finishNativeSourceCapabilityCheck(claim: check, capabilities: capabilities, outcome: .completed,
                        credential: credential, lease: await leaseState.current(), cancellation: cancellation)
                } catch {
                    try? await repository.finishNativeSourceCapabilityCheck(claim: check, capabilities: nil, outcome: .unknown,
                        credential: credential, lease: await leaseState.current(), cancellation: ToolCallCancellation(timeoutSeconds: 3))
                    throw error
                }
                _ = try await checkedConfiguration(assignment: assignment, preflight: preflight)
                let policy = try policyResolver(authenticated.descriptor.projectID, authenticated.descriptor.projectGeneration)
                let refreshed = try await repository.nativeSourcePreparedTurn(stageID: prepared.stageID, credential: credential,
                    lease: await leaseState.current(), cancellation: cancellation)
                let binding = try await repository.nativeSourceBudgetBinding(stageID: prepared.stageID, boundary: .beforeProviderPost,
                    credential: credential, lease: await leaseState.current(), cancellation: cancellation)
                let budget: NativeSourceProviderBudgetApproval
                switch NativeSourceBudgetEvaluator.providerDecision(prepared: refreshed, preflight: preflight,
                    capabilities: capabilities, policySelection: policy, binding: binding) {
                case .admitted(let value): budget = value
                case .pressure(let value):
                    return try await recordPressure(.pressure(value), credential: credential, leaseState: leaseState, policy: policy, cancellation: cancellation)
                case .blocked(let value):
                    return try await recordPressure(.blocked(value), credential: credential, leaseState: leaseState, policy: policy, cancellation: cancellation)
                }
                let admission = try await repository.beginNativeSourceProviderPost(prepared: prepared, preflight: preflight,
                    capabilities: capabilities, budget: budget, credential: credential, lease: await leaseState.current(), cancellation: cancellation)
                switch admission {
                case .accepted(let retained): accepted = retained
                case .inProgress, .outcomeUnknown: throw NativeSourceConversationError.outcomeUnknown
                case .dispatch(let claim):
                    do {
                        let request = prepared.request
                        let turn = try await boundedLeg(cancellation: cancellation) {
                            switch request {
                            case .root(let value): try await provider.createRoot(value, observedCapabilities: capabilities)
                            case .continuation(let value): try await provider.continueSession(value, observedCapabilities: capabilities)
                            }
                        }
                        accepted = try await repository.acceptNativeSourceProviderTurn(claim: claim, turn: turn,
                            credential: credential, lease: await leaseState.current(), cancellation: cancellation)
                    } catch {
                        try? await repository.recordNativeSourceProviderOutcome(claim: claim, outcome: .unknown,
                            cancellation: ToolCallCancellation(timeoutSeconds: 3))
                        throw error
                    }
                }
            }
            guard accepted.calls.count <= 16 else { throw NativeSourceConversationError.integrityFailure }
            let acceptedPolicy = try policyResolver(authenticated.descriptor.projectID, authenticated.descriptor.projectGeneration)
            let context = try await repository.nativeSourceAcceptedBudgetContext(stageID: accepted.prepared.stageID,
                credential: credential, lease: await leaseState.current(), cancellation: cancellation)
            switch NativeSourceBudgetEvaluator.acceptedDecision(context: context, policySelection: acceptedPolicy) {
            case .admitted: break
            case .pressure(let value):
                return try await recordPressure(.pressure(value), credential: credential, leaseState: leaseState, policy: acceptedPolicy, cancellation: cancellation)
            case .blocked(let value):
                return try await recordPressure(.blocked(value), credential: credential, leaseState: leaseState, policy: acceptedPolicy, cancellation: cancellation)
            }
            if accepted.calls.isEmpty { return nil }
            guard accepted.prepared.retainedCapabilities != nil,
                  let retainedPreflight = accepted.prepared.retainedPreflight else { throw NativeSourceConversationError.integrityFailure }
            var outputs: [NativeSourceProviderCallOutput] = []
            for reference in accepted.calls {
                try Task.checkCancellation(); try cancellation.checkCancellation()
                let currentLease = await leaseState.current()
                let resolved = try await repository.resolveNativeSourceProviderCall(reference: reference,
                    credential: credential, lease: currentLease, cancellation: cancellation)
                _ = try await checkedConfiguration(assignment: assignment, preflight: retainedPreflight)
                let policy = try policyResolver(resolved.attachment.descriptor.projectID, resolved.attachment.descriptor.projectGeneration)
                let output: NativeSourceProviderCallOutput
                if let retained = try await repository.nativeSourceProviderCallOutput(reference: reference, credential: credential,
                    lease: currentLease, policySelection: policy, cancellation: cancellation) {
                    output = retained
                } else {
                    let io = pressureIO
                    let evaluation = try await repository.evaluateNativeSourceToolOutput(reference: reference, credential: credential,
                        lease: currentLease, policySelection: policy, measureContinuation: { [self] request in
                            let measured = try await provider.preflightContinuation(request)
                            _ = try await checkedConfiguration(assignment: assignment, preflight: measured)
                            guard measured.configurationFingerprintSHA256 == retainedPreflight.configurationFingerprintSHA256 else {
                                throw NativeSourceConversationError.conflict
                            }
                            return measured
                        }, prepareCheckpoint: { try io.checkpoint($0, cancellation) }, cancellation: cancellation)
                    outputObserver(resolved, evaluation)
                    let budget: NativeSourceProviderOutputBudget
                    let checkpoint: PreparedContinuitySourceCommit?
                    switch evaluation {
                    case .admitted(let value, let frozen): budget = value; checkpoint = frozen
                    case .pressure(let claim): return claim
                    case .blocked: return nil
                    }
                    let callToken = ToolCallCancellation(timeoutSeconds: min(120, max(0, cancellation.remainingTimeInterval ?? 120)))
                    output = try await withTaskCancellationHandler {
                        try await call(credential, reference, await leaseState.current(), budget, checkpoint, callToken)
                    } onCancel: { callToken.cancel() }
                }
                if output.readyHandoffCommitted { return nil }
                outputs.append(output)
            }
            prepared = try await repository.prepareNativeSourceToolContinuation(acceptedStageID: accepted.prepared.stageID,
                credential: credential, lease: await leaseState.current(), cancellation: cancellation)
        }
        throw NativeSourceConversationError.budgetExceeded
    }

    private func recordPressure(_ metadata: NativeSourceBudgetMetadata, credential: NativeTaskCapabilityCredential,
        leaseState: NativeSourceLeaseState, policy: BudgetPolicySelection, cancellation: ToolCallCancellation) async throws -> NativeSourcePressureClaim? {
        switch try await repository.recordNativeSourceBudgetDisposition(metadata: metadata, credential: credential,
            lease: await leaseState.current(), policySelection: policy, cancellation: cancellation) {
        case .pressure(let claim): return claim
        case .blocked: return nil
        }
    }

    /// Called only after the inference task group has joined. Storage gets its
    /// own fixed deadline and never renews provider authority.
    private func storePressure(_ original: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential) async {
        let remaining = (ISO8601.date(from: original.storageDeadline) ?? clock.now()).timeIntervalSince(clock.now())
        let token = ToolCallCancellation(timeoutSeconds: min(20, max(0, remaining)))
        let io = pressureIO
        var claim = original
        var releaseClaim = false
        do {
            let commandID = try beginCommand(token)
            defer { commands.removeValue(forKey: commandID); operationGate.remove(commandID) }
            try await withTaskCancellationHandler {
                try Task.checkCancellation(); try token.checkCancellation()
                claim = try await repository.renewNativeSourcePressureClaim(claim: original, credential: credential, cancellation: token)
                let attachment = try await repository.authenticateNativeTaskCapability(credential: credential, cancellation: token)
                let policy = try policyResolver(attachment.descriptor.projectID, attachment.descriptor.projectGeneration)
                switch try await repository.prepareNativeSourceBudgetHandoff(claim: claim, credential: credential,
                    policySelection: policy, responsePreflight: io.preflight, cancellation: token) {
                case .completed: break
                case .commit(let admission):
                    switch try await repository.beginNativeSourcePressureCommitAttempt(admission: admission, claim: claim,
                        credential: credential, policySelection: policy,
                        readExisting: { try io.read($0, $1, token) }, cancellation: token) {
                    case .completed: break
                    case .commit(let attempt):
                        _ = try await repository.commitNativeSourceBudgetHandoff(attempt: attempt, claim: claim,
                            credential: credential, policySelection: policy,
                            readExisting: { try io.read($0, $1, token) },
                            commit: { try io.commit($0, $1, $2, token) }, cancellation: token)
                    }
                }
            } onCancel: { token.cancel() }
            releaseClaim = true
        } catch {
            releaseClaim = (try? await repository.deferNativeSourcePressureRetry(claim: claim, credential: credential,
                preparationError: error as? NativeSourcePressurePacketError)) ?? false
            // The durable pressure packet and consumed attempt remain available
            // for exact source readback; an error is never absence evidence.
        }
        // Retryable failures retain the short lease as a durable cooldown.
        // Success and permanent preparation failures release their ownership.
        if releaseClaim { _ = try? await repository.releaseNativeSourcePressureClaim(claim) }
    }

    private func boundedLeg<Value: Sendable>(cancellation: ToolCallCancellation,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try cancellation.checkCancellation(); try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(min(120, max(0, cancellation.remainingTimeInterval ?? 120))))
                throw NativeSourceConversationError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
    private static func stopReason(_ error: Error) -> String {
        if let error = error as? NativeSourceConversationError {
            switch error {
            case .budgetExceeded: return "source_budget_exceeded"
            case .unsupportedProvider: return "source_provider_unsupported"
            case .deadlineExceeded: return "source_deadline_exceeded"
            case .conflict: return "source_configuration_conflict"
            default: break
            }
        }
        return "source_preparation_failed"
    }
    private static func preflight(_ request: NativeSourceProviderRequest,
        provider: any ManagedModelProviderRequestPreflighting) async throws -> ProviderRequestPreflight {
        switch request {
        case .root(let value): try await provider.preflightRoot(value)
        case .continuation(let value): try await provider.preflightContinuation(value)
        }
    }
    private static func idempotencyKey(_ request: NativeSourceProviderRequest) -> String {
        switch request { case .root(let value): value.idempotencyKey; case .continuation(let value): value.idempotencyKey }
    }
    private static func tools(_ request: NativeSourceProviderRequest) -> [Data] {
        switch request { case .root(let value): value.tools; case .continuation(let value): value.tools }
    }
    static func emptyOutputRequest(accepted: NativeSourceAcceptedProviderTurn, outputs: [NativeSourceProviderCallOutput], callID: String) throws -> ProviderContinuationRequest {
        var items: [[String: Any]] = outputs.map { ["type": "function_call_output", "call_id": $0.callID,
            "output": String(decoding: $0.canonicalPayloadJSON, as: UTF8.self)] }
        // A nonempty serialization-only placeholder satisfies the transport contract.
        // The budget reserves its byte plus the complete actual escaped payload.
        items.append(["type": "function_call_output", "call_id": callID, "output": "0"])
        return try .init(operationID: accepted.prepared.stageID, idempotencyKey: Self.idempotencyKey(accepted.prepared.request),
            modelKey: accepted.turn.modelKey, previousResponseID: accepted.turn.responseID,
            input: ForgeJSONCanonicalizationV1.data(from: items), tools: Self.tools(accepted.prepared.request))
    }

    private func response(_ prepared: NativeSourcePreparedTurn, credential: NativeTaskCapabilityCredential,
                          disposition: String, cancellation: ToolCallCancellation) async throws -> NativeSourceOperatorResponse {
        let conversation = try await repository.nativeSourceConversationStatus(conversationID: prepared.conversationID,
            credential: credential, cancellation: cancellation)
        var value: [String: Any] = ["schema_version": 1, "ok": true, "disposition": disposition,
            "task_id": prepared.taskID.uuidString.lowercased(), "request_id": prepared.requestID.uuidString.lowercased(),
            "conversation_id": prepared.conversationID.uuidString.lowercased(), "conversation_state": conversation.state.rawValue,
            "stage_id": prepared.stageID.uuidString.lowercased(), "stage_state": prepared.state.rawValue,
            "stage_ordinal": prepared.ordinal, "deadline": prepared.deadline, "intent_sha256": prepared.intentSHA256]
        if let accepted = try await repository.nativeSourceRequestResult(taskID: prepared.taskID, requestID: prepared.requestID,
            credential: credential, cancellation: cancellation) {
            let text = accepted.turn.messages.joined(separator: "\n")
            let bytes = Data(text.utf8)
            var preview = String(decoding: bytes.prefix(4_096), as: UTF8.self)
            while preview.utf8.count > 4_096 { preview.removeLast() }
            value["assistant_preview"] = preview.replacingOccurrences(of: "\0", with: "")
            value["assistant_truncated"] = bytes.count > 4_096
            value["assistant_sha256"] = JSONSupport.sha256Hex(bytes)
        }
        return try NativeSourceOperatorResponse(arguments: value)
    }
}

private actor NativeSourceLeaseState {
    private var value: NativeSourceConversationLease
    init(_ value: NativeSourceConversationLease) { self.value = value }
    func current() -> NativeSourceConversationLease { value }
    func update(_ value: NativeSourceConversationLease) { self.value = value }
}

/// Synchronous manager stop/rebind fence. Entries are bounded by the actor's
/// eight commands and two exchanges; it never creates work during a signal.
final class NativeSourceOperationGate: @unchecked Sendable {
    private struct Entry {
        let cancellation: ToolCallCancellation
        let task: Task<Void, Never>?
        let requiresOperational: Bool
        let generation: UUID?
        func cancel() { cancellation.cancel(); task?.cancel() }
    }
    private let lock = NSLock()
    private var operational = false
    private var closed = false
    private var generation = UUID()
    private var entries: [UUID: Entry] = [:]
    var isOperational: Bool {
        lock.lock(); defer { lock.unlock() }; return operational && !closed
    }
    func register(_ id: UUID, cancellation: ToolCallCancellation, requiresOperational: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !requiresOperational || operational, entries.count < 10, entries[id] == nil else { return false }
        entries[id] = Entry(cancellation: cancellation, task: nil, requiresOperational: requiresOperational,
            generation: requiresOperational ? generation : nil)
        return true
    }
    @discardableResult
    func bind(_ id: UUID, originatingCommandID: UUID,
        cancellation: ToolCallCancellation, task: Task<Void, Never>) -> Bool {
        lock.lock()
        let entry = Entry(cancellation: cancellation, task: task, requiresOperational: true, generation: generation)
        let command = entries[originatingCommandID]
        let retain = !closed && operational && entries.count < 10 && entries[id] == nil
            && command?.task == nil && command?.requiresOperational == true && command?.generation == generation
            && command?.cancellation.isCancelled == false && command?.cancellation.isDeadlineExceeded == false
            && !cancellation.isCancelled && !cancellation.isDeadlineExceeded
        if retain { entries[id] = entry }
        lock.unlock()
        if !retain { entry.cancel() }
        return retain
    }
    func remove(_ id: UUID) { lock.lock(); entries.removeValue(forKey: id); lock.unlock() }
    func setOperational(_ value: Bool) {
        lock.lock()
        operational = value && !closed
        // Invalidate old registrations before releasing the lock or invoking cancellation.
        // Reopening the service never restores a prior command's handover authority.
        if !value { generation = UUID() }
        let cancelled = operational ? [] : entries.values.filter(\.requiresOperational)
        lock.unlock()
        for entry in cancelled { entry.cancel() }
    }
    func close() {
        lock.lock(); closed = true; operational = false; generation = UUID()
        let cancelled = Array(entries.values)
        lock.unlock()
        for entry in cancelled { entry.cancel() }
    }
}

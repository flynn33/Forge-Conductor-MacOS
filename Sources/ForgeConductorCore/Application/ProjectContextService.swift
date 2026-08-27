// ProjectContextService.swift
// Bridges synchronous tool adapters to the actor-owned durable project control plane.

import Foundation

public final class ProjectContextService: @unchecked Sendable {
    public static let defaultInlineOutputLimit = 64 * 1_024

    public let repository: ProjectControlPlaneRepository
    private let waitTimeoutSeconds: TimeInterval
    private let cancellationCleanupTimeoutSeconds: TimeInterval
    /// The repository actor is serial, so admit at most one bridging task. Requests
    /// waiting behind it remain cancellable without adding an unbounded actor mailbox.
    private let operationAdmission = DispatchSemaphore(value: 1)

    public init(
        databaseURL: URL,
        clock: any Clock = SystemClock(),
        waitTimeout: DispatchTimeInterval = .seconds(10),
        cancellationCleanupTimeout: DispatchTimeInterval = .seconds(10)
    ) throws {
        self.repository = try ProjectControlPlaneRepository(databaseURL: databaseURL, clock: clock)
        self.waitTimeoutSeconds = Self.boundedSeconds(waitTimeout, fallback: 10)
        self.cancellationCleanupTimeoutSeconds = Self.boundedSeconds(
            cancellationCleanupTimeout,
            fallback: 10
        )
    }

    public func registerAndBindMCPClient(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL,
        clientID: ClientID,
        allowedTools: Set<String> = ["*"],
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        try cancellation?.checkCancellation()
        guard let rawProjectID = UUID(uuidString: descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        let projectID = ProjectID(rawProjectID)
        let root = canonicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let project = try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.registerProject(
                projectID: projectID,
                displayName: descriptor.displayName,
                canonicalRoot: root,
                repositoryFingerprint: descriptor.repositoryIdentity,
                cancellation: control
            )
        }
        let owner = ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [project.canonicalRoot],
            allowedTools: allowedTools,
            networkAllowed: false,
            maximumInlineOutputBytes: maximumInlineOutputBytes
        )
        // Project registration is durable. Complete the idempotent binding even
        // if transport cancellation races this second commit.
        let binding = try wait(cancellation: nil, committedResultWins: true) { control in
            try await self.repository.bind(
                owner: owner,
                projectID: project.projectID,
                generation: project.generation,
                authorizationScope: scope,
                cancellation: control
            )
        }
        return binding.invocationContext(clientID: clientID)
    }

    public func registerProject(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        guard let rawProjectID = UUID(uuidString: descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        let root = canonicalRoot.resolvingSymlinksInPath().standardizedFileURL
        return try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.registerProject(
                projectID: ProjectID(rawProjectID),
                displayName: descriptor.displayName,
                canonicalRoot: root,
                repositoryFingerprint: descriptor.repositoryIdentity,
                cancellation: control
            )
        }
    }

    public func project(
        _ projectID: ProjectID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.project(projectID, cancellation: control)
        }
    }

    public func bind(
        owner: ProjectBindingOwner,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID? = nil,
        authorizationScope: ToolAuthorizationScope,
        leaseOwner: String? = nil,
        leaseExpiresAt: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectContextBinding {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.bind(
                owner: owner,
                projectID: projectID,
                generation: generation,
                runID: runID,
                authorizationScope: authorizationScope,
                leaseOwner: leaseOwner,
                leaseExpiresAt: leaseExpiresAt,
                cancellation: control
            )
        }
    }

    public func invocationContext(
        for clientID: ClientID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        let owner = ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        return try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.invocationContext(
                for: owner,
                clientID: clientID,
                cancellation: control
            )
        }
    }

    public func invocationContext(
        for owner: ProjectBindingOwner,
        clientID: ClientID? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.invocationContext(
                for: owner,
                clientID: clientID,
                cancellation: control
            )
        }
    }

    public func validate(
        _ context: ToolInvocationContext,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        let owner = Self.owner(for: context)
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.validate(
                context,
                for: owner,
                cancellation: control
            )
        }
    }

    public func validate(
        _ context: ToolInvocationContext,
        for owner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.validate(
                context,
                for: owner,
                cancellation: control
            )
        }
    }

    public func commitIfCurrent<Value: Sendable>(
        context: ToolInvocationContext,
        resultKind: String,
        resultSHA256: String? = nil,
        cancellation: ToolCallCancellation? = nil,
        mutation: @escaping @Sendable (ToolCallCancellation) throws -> Value
    ) throws -> Value {
        let owner = Self.owner(for: context)
        return try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.commitIfCurrent(
                context: context,
                owner: owner,
                resultKind: resultKind,
                resultSHA256: resultSHA256,
                cancellation: control,
                mutation: { try mutation(control) }
            )
        }
    }

    public func beginReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.beginReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                cancellation: control
            )
        }
    }

    public func completeReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectGenerationResetReceipt {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.completeReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                cancellation: control
            )
        }
    }

    public func cancelReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.cancelReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                cancellation: control
            )
        }
    }

    public func health(
        cancellation: ToolCallCancellation? = nil
    ) throws -> ControlPlaneDatabaseHealth {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.health(cancellation: control)
        }
    }

    public func close() {
        _ = try? wait(cancellation: nil, committedResultWins: false) { _ in
            await self.repository.close()
            return true
        }
    }

    public static func owner(for context: ToolInvocationContext) -> ProjectBindingOwner {
        if let runtimeJobID = context.runtimeJobID {
            return ProjectBindingOwner(kind: .runtimeJob, id: runtimeJobID.uuidString.lowercased())
        }
        if let providerSessionID = context.providerSessionID {
            return ProjectBindingOwner(kind: .providerSession, id: providerSessionID)
        }
        if let runID = context.runID {
            return ProjectBindingOwner(kind: .autonomousRun, id: runID.description)
        }
        return ProjectBindingOwner(kind: .mcpClient, id: context.clientID.rawValue)
    }

    private func wait<Value: Sendable>(
        cancellation: ToolCallCancellation?,
        committedResultWins: Bool,
        _ operation: @escaping @Sendable (ToolCallCancellation) async throws -> Value
    ) throws -> Value {
        let operationControl = cancellation
            ?? ToolCallCancellation(timeoutSeconds: waitTimeoutSeconds)
        try acquireOperationAdmission(
            cancellation: operationControl,
            mapsInternalDeadlineToBusy: cancellation == nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingProjectContextResult<Value>()
        // The synchronous caller may own the main actor. Run independently, retain
        // the handle, and reconcile it before returning on cancellation or timeout.
        let task = Task.detached {
            defer { self.operationAdmission.signal() }
            do {
                box.store(.success(try await operation(operationControl)))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(waitTimeoutSeconds)
        while semaphore.wait(timeout: .now() + .milliseconds(25)) != .success {
            do {
                try operationControl.checkCancellation()
            } catch {
                let initiatingError: Error = cancellation == nil
                    && error is ToolCallDeadlineExceeded
                    ? ProjectContextError.databaseBusy
                    : error
                return try stopAndReconcile(
                    task: task,
                    semaphore: semaphore,
                    box: box,
                    cancellation: operationControl,
                    initiatingError: initiatingError,
                    committedResultWins: committedResultWins,
                    reason: "request cancellation"
                )
            }
            guard clock.now < deadline else {
                return try stopAndReconcile(
                    task: task,
                    semaphore: semaphore,
                    box: box,
                    cancellation: operationControl,
                    initiatingError: ProjectContextError.databaseBusy,
                    committedResultWins: committedResultWins,
                    reason: "bounded wait timeout"
                )
            }
        }
        guard let result = box.take() else {
            throw ProjectContextError.databaseFailure("project context operation completed without a result")
        }
        switch result {
        case .success(let value):
            if !committedResultWins {
                try operationControl.checkCancellation()
            }
            return value
        case .failure(let error):
            if committedResultWins,
               let receipt: Value = operationControl.committedResult() {
                return receipt
            }
            if cancellation == nil, error is ToolCallDeadlineExceeded {
                throw ProjectContextError.databaseBusy
            }
            throw error
        }
    }

    private func stopAndReconcile<Value: Sendable>(
        task: Task<Void, Never>,
        semaphore: DispatchSemaphore,
        box: BlockingProjectContextResult<Value>,
        cancellation: ToolCallCancellation?,
        initiatingError: Error,
        committedResultWins: Bool,
        reason: String
    ) throws -> Value {
        cancellation?.cancel()
        task.cancel()
        guard committedResultWins else { throw initiatingError }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(cancellationCleanupTimeoutSeconds)
        while semaphore.wait(timeout: .now() + .milliseconds(25)) != .success,
              clock.now < deadline {}
        if committedResultWins,
           let receipt: Value = cancellation?.committedResult() {
            return receipt
        }
        guard let result = box.take() else {
            throw ProjectContextError.databaseFailure(
                "project context \(reason) exceeded its cancellation cleanup deadline"
            )
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error) where error is CancellationError
            || error is ToolCallDeadlineExceeded:
            throw initiatingError
        case .failure(let error):
            throw error
        }
    }

    private func acquireOperationAdmission(
        cancellation: ToolCallCancellation,
        mapsInternalDeadlineToBusy: Bool
    ) throws {
        while operationAdmission.wait(timeout: .now() + .milliseconds(25)) != .success {
            do {
                try cancellation.checkCancellation()
            } catch is ToolCallDeadlineExceeded where mapsInternalDeadlineToBusy {
                throw ProjectContextError.databaseBusy
            }
        }
        do {
            try cancellation.checkCancellation()
        } catch {
            operationAdmission.signal()
            if mapsInternalDeadlineToBusy, error is ToolCallDeadlineExceeded {
                throw ProjectContextError.databaseBusy
            }
            throw error
        }
    }

    private static func boundedSeconds(
        _ interval: DispatchTimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        let seconds: TimeInterval
        switch interval {
        case .seconds(let value):
            seconds = TimeInterval(value)
        case .milliseconds(let value):
            seconds = TimeInterval(value) / 1_000
        case .microseconds(let value):
            seconds = TimeInterval(value) / 1_000_000
        case .nanoseconds(let value):
            seconds = TimeInterval(value) / 1_000_000_000
        case .never:
            seconds = fallback
        @unknown default:
            seconds = fallback
        }
        return min(60, max(0.025, seconds.isFinite ? seconds : fallback))
    }
}

private final class BlockingProjectContextResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

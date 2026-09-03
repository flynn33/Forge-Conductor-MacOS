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

    /// Source-compatible facade for the pre-coordinator API. The former
    /// implementation trusted a caller-supplied descriptor and could mutate the
    /// control plane without publishing the corresponding project identity. It
    /// now fails closed; callers must use ManagerNode or the manager-owned MCP
    /// bootstrap coordinator.
    @available(*, deprecated, message: "Use ManagerNode or ToolRouter project registration")
    public func registerAndBindMCPClient(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL,
        clientID: ClientID,
        allowedTools: Set<String> = ["*"],
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        _ = descriptor
        _ = canonicalRoot
        _ = clientID
        _ = allowedTools
        _ = maximumInlineOutputBytes
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    func registerAndBindMCPClientUnchecked(
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
            try await self.repository.registerProjectUnchecked(
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

    func bindMCPClient(
        project: ProjectControlRecord,
        clientID: ClientID,
        allowedTools: Set<String> = ["*"],
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        let owner = ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [project.canonicalRoot],
            allowedTools: allowedTools,
            networkAllowed: false,
            maximumInlineOutputBytes: maximumInlineOutputBytes
        )
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

    /// Source-compatible facade for the pre-coordinator registration API.
    /// It intentionally performs no mutation because the caller-provided
    /// descriptor cannot prove project-memory publication authority.
    @available(*, deprecated, message: "Use ManagerNode or ToolRouter project registration")
    public func registerProject(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        _ = descriptor
        _ = canonicalRoot
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    func registerProjectUnchecked(
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
            try await self.repository.registerProjectUnchecked(
                projectID: ProjectID(rawProjectID),
                displayName: descriptor.displayName,
                canonicalRoot: root,
                repositoryFingerprint: descriptor.repositoryIdentity,
                cancellation: control
            )
        }
    }

    func prepareControlledRegistration(
        identities: ProjectIdentityResolver,
        target: ProjectIdentityTarget,
        requestedProjectID: String?,
        displayName: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRegistrationIdentityPreparation {
        try cancellation?.checkCancellation()
        let rootOwner = try project(
            atCanonicalRoot: target.canonicalRoot,
            cancellation: cancellation
        )
        let identityOwner = try target.repositoryIdentity.flatMap { identity in
            try project(repositoryFingerprint: identity, cancellation: cancellation)
        }
        if let rootOwner, let identityOwner,
           rootOwner.projectID != identityOwner.projectID {
            throw ProjectContextError.integrityFailure(
                "canonical root and repository identity belong to different projects"
            )
        }
        let controlled = identityOwner ?? rootOwner
        if let controlled {
            guard controlled.lifecycleState == .active
                    || controlled.lifecycleState == .maintenance else {
                throw ProjectContextError.projectNotActive(controlled.lifecycleState)
            }
            guard controlled.canonicalRoot == target.canonicalRoot else {
                throw ProjectContextError.projectRelinkRequired(controlled.projectID)
            }
            if controlled.repositoryFingerprint != target.repositoryIdentity {
                guard controlled.repositoryFingerprint == nil,
                      target.repositoryIdentity != nil,
                      controlled.canonicalRoot == target.canonicalRoot else {
                    throw ProjectContextError.projectRepositoryIdentityMismatch(
                        controlled.projectID
                    )
                }
            }
            if let requestedProjectID,
               requestedProjectID.caseInsensitiveCompare(
                   controlled.projectID.description
               ) != .orderedSame {
                throw ProjectContextError.projectScopeMismatch
            }
        }
        let preparation = try identities.prepareRegistration(
            target: target,
            requestedProjectID: controlled?.projectID.description ?? requestedProjectID,
            displayName: displayName,
            allowUnregisteredRequestedID: controlled != nil,
            expectedControlGeneration: controlled?.generation,
            expectedControlLifecycleState: controlled?.lifecycleState,
            expectedControlRepositoryIdentity: controlled?.repositoryFingerprint,
            cancellation: cancellation
        )
        if let controlled,
           preparation.descriptor.id.caseInsensitiveCompare(
               controlled.projectID.description
           ) != .orderedSame {
            throw ProjectContextError.projectScopeMismatch
        }
        return preparation
    }

    func validateControlledRegistration(
        _ captured: ProjectRegistrationIdentityPreparation,
        identities: ProjectIdentityResolver,
        requestedProjectID: String?,
        displayName: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        let current = try prepareControlledRegistration(
            identities: identities,
            target: captured.target,
            requestedProjectID: requestedProjectID,
            displayName: displayName,
            cancellation: cancellation
        )
        guard current == captured else {
            throw ProjectMemoryError.conflict(
                "project registration authority changed before control-plane acceptance"
            )
        }
    }

    func registerProject(
        preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        guard let rawProjectID = UUID(uuidString: preparation.descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        return try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.registerProjectUnchecked(
                projectID: ProjectID(rawProjectID),
                displayName: preparation.descriptor.displayName,
                canonicalRoot: preparation.target.canonicalRoot,
                repositoryFingerprint: preparation.target.repositoryIdentity,
                controlExpectation: preparation.expectedControlGeneration.map {
                    .existing($0)
                } ?? .absent,
                targetDirectoryIdentity: preparation.target.directoryIdentity,
                disposition: preparation.expectedControlLifecycleState == .active
                        && preparation.expectedControlRepositoryIdentity
                            == preparation.target.repositoryIdentity
                        && preparation.descriptor.aliases.contains(
                            preparation.target.canonicalRoot.path
                        )
                    ? .active
                    : .awaitingIdentityPublication,
                transitionOperationID: preparation.operationID,
                cancellation: control
            )
        }
    }

    func finalizeRegistration(
        preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        guard let rawProjectID = UUID(uuidString: preparation.descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        let projectID = ProjectID(rawProjectID)
        if preparation.expectedControlLifecycleState == .active,
           preparation.expectedControlRepositoryIdentity
                == preparation.target.repositoryIdentity,
           preparation.descriptor.aliases.contains(
                preparation.target.canonicalRoot.path
           ) {
            guard let current = try project(projectID, cancellation: cancellation) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.lifecycleState == .active,
                  current.generation == preparation.expectedControlGeneration,
                  current.canonicalRoot == preparation.target.canonicalRoot,
                  current.repositoryFingerprint == preparation.target.repositoryIdentity else {
                throw ProjectContextError.projectTransitionConflict(projectID)
            }
            return current
        }
        return try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.finalizeRegistration(
                projectID: projectID,
                generation: preparation.expectedControlGeneration ?? .initial,
                target: preparation.target,
                transitionOperationID: preparation.operationID,
                cancellation: control
            )
        }
    }

    func validateRegistrationPublicationAuthority(
        preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        guard let rawProjectID = UUID(uuidString: preparation.descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.validateRegistrationPublicationAuthority(
                projectID: ProjectID(rawProjectID),
                generation: preparation.expectedControlGeneration ?? .initial,
                target: preparation.target,
                transitionOperationID: preparation.operationID,
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

    func project(
        atCanonicalRoot canonicalRoot: URL,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.project(
                atCanonicalRoot: canonicalRoot,
                cancellation: control
            )
        }
    }

    func project(
        repositoryFingerprint: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.project(
                repositoryFingerprint: repositoryFingerprint,
                cancellation: control
            )
        }
    }

    /// Source-compatible facade for the pre-coordinator relink API. Relink now
    /// requires a durable identity stage, retained-authority fence, control-plane
    /// compare-and-set, and alias publication owned by ManagerNode.
    @available(*, deprecated, message: "Use ManagerNode.relinkProject(projectID:expectedGeneration:path:)")
    public func relinkProject(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        newCanonicalRoot: URL,
        repositoryFingerprint: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkReceipt {
        _ = projectID
        _ = expectedGeneration
        _ = newCanonicalRoot
        _ = repositoryFingerprint
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    func relinkProjectUnchecked(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        newCanonicalRoot: URL,
        repositoryFingerprint: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkReceipt {
        let root = newCanonicalRoot.resolvingSymlinksInPath().standardizedFileURL
        return try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.relinkProjectUnchecked(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                newCanonicalRoot: root,
                repositoryFingerprint: repositoryFingerprint,
                cancellation: control
            )
        }
    }

    func relinkProject(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkReceipt {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.relinkProjectUnchecked(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                newCanonicalRoot: target.canonicalRoot,
                repositoryFingerprint: target.repositoryIdentity,
                targetDirectoryIdentity: target.directoryIdentity,
                disposition: .awaitingIdentityPublication,
                transitionOperationID: transitionOperationID,
                cancellation: control
            )
        }
    }

    func finalizeRelink(
        projectID: ProjectID,
        priorGeneration: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try wait(cancellation: cancellation, committedResultWins: true) { control in
            try await self.repository.finalizeRelink(
                projectID: projectID,
                priorGeneration: priorGeneration,
                target: target,
                transitionOperationID: transitionOperationID,
                cancellation: control
            )
        }
    }

    func validateRelinkPublicationAuthority(
        projectID: ProjectID,
        priorGeneration: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try wait(cancellation: cancellation, committedResultWins: false) { control in
            try await self.repository.validateRelinkPublicationAuthority(
                projectID: projectID,
                priorGeneration: priorGeneration,
                target: target,
                transitionOperationID: transitionOperationID,
                cancellation: control
            )
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

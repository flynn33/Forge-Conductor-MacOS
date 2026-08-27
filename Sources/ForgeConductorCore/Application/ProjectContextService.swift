// ProjectContextService.swift
// Bridges synchronous tool adapters to the actor-owned durable project control plane.

import Foundation

public final class ProjectContextService: @unchecked Sendable {
    public static let defaultInlineOutputLimit = 64 * 1_024

    public let repository: ProjectControlPlaneRepository
    private let waitTimeout: DispatchTimeInterval

    public init(
        databaseURL: URL,
        clock: any Clock = SystemClock(),
        waitTimeout: DispatchTimeInterval = .seconds(10)
    ) throws {
        self.repository = try ProjectControlPlaneRepository(databaseURL: databaseURL, clock: clock)
        self.waitTimeout = waitTimeout
    }

    public func registerAndBindMCPClient(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL,
        clientID: ClientID,
        allowedTools: Set<String> = ["*"],
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit
    ) throws -> ToolInvocationContext {
        guard let rawProjectID = UUID(uuidString: descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        let projectID = ProjectID(rawProjectID)
        let root = canonicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let project = try wait {
            try await self.repository.registerProject(
                projectID: projectID,
                displayName: descriptor.displayName,
                canonicalRoot: root,
                repositoryFingerprint: descriptor.repositoryIdentity
            )
        }
        let owner = ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [project.canonicalRoot],
            allowedTools: allowedTools,
            networkAllowed: false,
            maximumInlineOutputBytes: maximumInlineOutputBytes
        )
        let binding = try wait {
            try await self.repository.bind(
                owner: owner,
                projectID: project.projectID,
                generation: project.generation,
                authorizationScope: scope
            )
        }
        return binding.invocationContext(clientID: clientID)
    }

    public func registerProject(
        descriptor: ProjectMemoryDescriptor,
        canonicalRoot: URL
    ) throws -> ProjectControlRecord {
        guard let rawProjectID = UUID(uuidString: descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        let root = canonicalRoot.resolvingSymlinksInPath().standardizedFileURL
        return try wait {
            try await self.repository.registerProject(
                projectID: ProjectID(rawProjectID),
                displayName: descriptor.displayName,
                canonicalRoot: root,
                repositoryFingerprint: descriptor.repositoryIdentity
            )
        }
    }

    public func project(_ projectID: ProjectID) throws -> ProjectControlRecord? {
        try wait { try await self.repository.project(projectID) }
    }

    public func bind(
        owner: ProjectBindingOwner,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID? = nil,
        authorizationScope: ToolAuthorizationScope,
        leaseOwner: String? = nil,
        leaseExpiresAt: String? = nil
    ) throws -> ProjectContextBinding {
        try wait {
            try await self.repository.bind(
                owner: owner,
                projectID: projectID,
                generation: generation,
                runID: runID,
                authorizationScope: authorizationScope,
                leaseOwner: leaseOwner,
                leaseExpiresAt: leaseExpiresAt
            )
        }
    }

    public func invocationContext(for clientID: ClientID) throws -> ToolInvocationContext {
        let owner = ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
        return try wait {
            try await self.repository.invocationContext(for: owner, clientID: clientID)
        }
    }

    public func invocationContext(for owner: ProjectBindingOwner, clientID: ClientID? = nil) throws -> ToolInvocationContext {
        try wait {
            try await self.repository.invocationContext(for: owner, clientID: clientID)
        }
    }

    public func validate(_ context: ToolInvocationContext) throws {
        let owner = Self.owner(for: context)
        try wait {
            try await self.repository.validate(context, for: owner)
        }
    }

    public func validate(_ context: ToolInvocationContext, for owner: ProjectBindingOwner) throws {
        try wait {
            try await self.repository.validate(context, for: owner)
        }
    }

    public func commitIfCurrent<Value: Sendable>(
        context: ToolInvocationContext,
        resultKind: String,
        resultSHA256: String? = nil,
        mutation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        let owner = Self.owner(for: context)
        return try wait {
            try await self.repository.commitIfCurrent(
                context: context,
                owner: owner,
                resultKind: resultKind,
                resultSHA256: resultSHA256,
                mutation: mutation
            )
        }
    }

    public func beginReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration
    ) throws -> ProjectControlRecord {
        try wait {
            try await self.repository.beginReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration
            )
        }
    }

    public func completeReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration
    ) throws -> ProjectGenerationResetReceipt {
        try wait {
            try await self.repository.completeReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration
            )
        }
    }

    public func cancelReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration
    ) throws {
        try wait {
            try await self.repository.cancelReset(
                projectID: projectID,
                expectedGeneration: expectedGeneration
            )
        }
    }

    public func health() throws -> ControlPlaneDatabaseHealth {
        try wait { try await self.repository.health() }
    }

    public func close() {
        _ = try? wait {
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
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingProjectContextResult<Value>()
        Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + waitTimeout) == .success else {
            throw ProjectContextError.databaseBusy
        }
        guard let result = box.take() else {
            throw ProjectContextError.databaseFailure("project context operation completed without a result")
        }
        return try result.get()
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

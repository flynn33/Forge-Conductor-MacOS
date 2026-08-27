// RuntimeJobSubsystem.swift
// Collision-free composition and legacy-shell seams for the durable runtime service.

import Foundation

public struct RuntimeJobSubsystem: Sendable {
    public let repository: RuntimeJobRepository
    public let service: ExecutionJobService
    public let toolPack: RuntimeJobToolPack
    public let legacyShell: LegacyShellJobAdapter

    public init(
        controlPlaneRepository: ProjectControlPlaneRepository,
        databaseURL: URL,
        artifactRoot: URL,
        limits: RuntimeJobLimits = .current,
        capabilityDiscoverer: RuntimeCapabilityDiscoverer = RuntimeCapabilityDiscoverer()
    ) throws {
        let repository = try RuntimeJobRepository(databaseURL: databaseURL)
        let service = try ExecutionJobService(
            repository: repository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: controlPlaneRepository
            ),
            artifactRoot: artifactRoot,
            limits: limits,
            capabilityDiscoverer: capabilityDiscoverer
        )
        self.repository = repository
        self.service = service
        toolPack = RuntimeJobToolPack(service: service)
        legacyShell = LegacyShellJobAdapter(service: service)
    }

    public func start() async throws {
        try await service.start()
    }

    @discardableResult
    public func shutdown() async -> RuntimeJobShutdownReport {
        let report = await service.shutdown()
        if report.completed {
            await repository.close()
        }
        return report
    }
}

/// Synchronous compatibility edge used by the existing MCP/tool-router contract.
/// Runtime ownership and process work remain on the subsystem actors; this edge only
/// waits for the bounded async result on the caller's transport thread.
public struct RuntimeJobSynchronousToolPack: ToolPackHandling, Sendable {
    public static let controlTimeoutSeconds: TimeInterval = 15
    public static let legacyCompletionSlackSeconds: TimeInterval = 10

    private let subsystem: RuntimeJobSubsystem

    public init(subsystem: RuntimeJobSubsystem) {
        self.subsystem = subsystem
    }

    public var toolNames: [String] {
        (RuntimeJobToolPack.names + ["shell_exec"]).sorted()
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        return .failure(
            code: ProjectContextError.projectContextRequired(
                ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue)
            ).code,
            message: "Runtime tools require a durable project context",
            retryable: false
        )
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        guard let context else {
            return try handle(
                name: name,
                arguments: arguments,
                clientID: clientID,
                app: app
            )
        }
        if name == "shell_exec" {
            return try handleLegacyShell(arguments: arguments, context: context, app: app)
        }
        return try Self.wait(timeoutSeconds: Self.controlTimeoutSeconds) {
            await subsystem.toolPack.handle(name: name, arguments: arguments, context: context)
                ?? .failure(code: "unknown_tool", message: "Unknown tool '\(name)'", retryable: false)
        }
    }

    private func handleLegacyShell(
        arguments: [String: Any],
        context: ToolInvocationContext,
        app: ForgeApp
    ) throws -> ToolResult {
        guard let command = ToolArgHelpers.string(arguments, "command"), !command.isEmpty else {
            return .failure(code: "missing_command", message: "command required")
        }
        let requestedTimeout = (arguments["timeout_sec"] as? NSNumber)?.doubleValue
            ?? Double(app.config.int("shell", "default_timeout_sec", default: 30))
        guard requestedTimeout.isFinite, requestedTimeout > 0 else {
            return .failure(
                code: "invalid_timeout",
                message: "timeout_sec must be finite and positive",
                retryable: false
            )
        }
        let timeout = min(requestedTimeout, Double(LegacyShellJobAdapter.maximumTimeoutSeconds))
        let cwd = ToolArgHelpers.string(arguments, "cwd")
            .map(ToolArgHelpers.resolvePath)
            ?? context.authorizationScope.canonicalRoots.first
            ?? app.paths.home
        let replayClass = ToolArgHelpers.string(arguments, "replay_class")
            .flatMap(RuntimeReplayClass.init(rawValue:))
            ?? .nonReplayable
        return try Self.wait(
            timeoutSeconds: timeout + Self.legacyCompletionSlackSeconds
        ) {
            try await subsystem.legacyShell.execute(
                command: command,
                workingDirectory: cwd,
                timeoutSeconds: Int(timeout.rounded(.up)),
                context: context,
                replayClass: replayClass,
                idempotencyKey: ToolArgHelpers.string(arguments, "idempotency_key")
            )
        }
    }

    private static func wait<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let result = RuntimeBlockingResult<Value>()
        Task.detached {
            do {
                result.store(.success(try await operation()))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(0.1, timeoutSeconds)) == .success else {
            throw RuntimeJobError.storageFailure("runtime transport wait exceeded its bounded deadline")
        }
        guard let value = result.take() else {
            throw RuntimeJobError.storageFailure("runtime transport completed without a result")
        }
        return try value.get()
    }
}

private final class RuntimeBlockingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

public struct LegacyShellJobAdapter: Sendable {
    public static let maximumTimeoutSeconds = 120
    public static let maximumStdoutBytes = 80_000
    public static let maximumStderrBytes = 20_000

    private let service: ExecutionJobService

    public init(service: ExecutionJobService) {
        self.service = service
    }

    public func execute(
        command: String,
        workingDirectory: URL,
        timeoutSeconds: Int,
        context: ToolInvocationContext,
        replayClass: RuntimeReplayClass = .nonReplayable,
        idempotencyKey: String? = nil
    ) async throws -> ToolResult {
        guard !command.isEmpty else {
            return .failure(code: "missing_command", message: "command required")
        }
        guard timeoutSeconds > 0 else {
            return .failure(
                code: "invalid_timeout",
                message: "timeout_sec must be finite and positive",
                retryable: false
            )
        }
        let boundedTimeout = min(timeoutSeconds, Self.maximumTimeoutSeconds)
        let jobID = try await service.submitLegacyBashLogin(
            command: command,
            workingDirectory: workingDirectory,
            timeoutSeconds: boundedTimeout,
            context: context,
            replayClass: replayClass,
            idempotencyKey: idempotencyKey
        )
        let record = try await service.waitForTerminal(
            jobID: jobID,
            context: context,
            maximumWait: .seconds(boundedTimeout + 5)
        )
        guard record.state.isTerminal else {
            return .failure(
                code: "runtime_terminal_commit_pending",
                message: "Runtime process ended but its terminal record is pending recovery",
                retryable: true
            )
        }
        let stdout = try await read(
            jobID: jobID,
            stream: .stdout,
            maximumBytes: Self.maximumStdoutBytes,
            context: context
        )
        let stderr = try await read(
            jobID: jobID,
            stream: .stderr,
            maximumBytes: Self.maximumStderrBytes,
            context: context
        )
        let timedOut = record.state == .timedOut
        let ok = record.exitCode == 0 && !timedOut && record.state == .completed
        return ToolResult(
            ok: ok,
            payload: [
                "ok": ok,
                "exit_code": record.exitCode ?? 255,
                "stdout": String(decoding: stdout.data, as: UTF8.self),
                "stderr": String(decoding: stderr.data, as: UTF8.self),
                "timed_out": timedOut,
                "stdout_truncated": stdout.truncated,
                "stderr_truncated": stderr.truncated,
                "command": command,
                "cwd": workingDirectory.path,
            ],
            isError: !ok
        )
    }

    private func read(
        jobID: UUID,
        stream: RuntimeOutputStream,
        maximumBytes: Int,
        context: ToolInvocationContext
    ) async throws -> (data: Data, truncated: Bool) {
        var data = Data()
        data.reserveCapacity(maximumBytes)
        var offset: UInt64 = 0
        var observed: UInt64 = 0
        while data.count < maximumBytes {
            let slice: RuntimeOutputSlice
            do {
                slice = try await service.readOutput(
                    jobID: jobID,
                    stream: stream,
                    offset: offset,
                    limit: min(64 * 1_024, maximumBytes - data.count),
                    context: context
                )
            } catch let error as RuntimeJobError where error.code == "runtime_output_unavailable" {
                return (data, false)
            }
            data.append(slice.data)
            observed = slice.totalObservedBytes
            guard !slice.eof, slice.nextOffset > offset else { break }
            offset = slice.nextOffset
        }
        return (data, observed > UInt64(data.count))
    }
}

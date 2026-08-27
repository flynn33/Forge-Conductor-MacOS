// RuntimeJobToolPack.swift
// Async contextual tool surface for durable runtime jobs; registration is composed by the manager.

import Foundation

public protocol AsyncContextualToolPackHandling: Sendable {
    var toolNames: [String] { get }
    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) async -> ToolResult?
}

public struct RuntimeJobToolPack: AsyncContextualToolPackHandling, Sendable {
    public static let names = [
        "runtime.capabilities",
        "process.run",
        "shell.run",
        "bash.run",
        "python.run",
        "powershell.run",
        "job.status",
        "job.read_output",
        "job.cancel",
        "job.list",
    ]

    private let service: ExecutionJobService

    public init(service: ExecutionJobService) {
        self.service = service
    }

    public var toolNames: [String] { Self.names }

    public static func description(for name: String) -> String? {
        [
            "runtime.capabilities": "Report direct process and external runtime availability plus enforced job limits.",
            "process.run": "Start a durable direct executable/argument-vector job without shell parsing.",
            "shell.run": "Start a durable staged zsh job with startup files disabled.",
            "bash.run": "Start a durable staged Bash job with profile and rc files disabled.",
            "python.run": "Start a durable isolated Python job when the configured interpreter is available.",
            "powershell.run": "Start a durable noninteractive PowerShell job when pwsh is available.",
            "job.status": "Read durable status for one project-generation-bound runtime job.",
            "job.read_output": "Read one bounded stdout or stderr slice from a durable runtime job.",
            "job.cancel": "Cancel a runtime job and terminate its process group with bounded escalation.",
            "job.list": "List a bounded page of runtime jobs in the current project generation.",
        ][name]
    }

    public static func schema(for name: String) -> [String: Any]? {
        guard names.contains(name) else { return nil }
        let string: [String: Any] = ["type": "string"]
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ]
        }
        let common: [String: Any] = [
            "cwd": string,
            "timeout_sec": ["type": "integer", "minimum": 1, "maximum": 86_400],
            "maximum_inline_output_bytes": ["type": "integer", "minimum": 1, "maximum": 65_536],
            "replay_class": [
                "type": "string",
                "enum": RuntimeReplayClass.allCases.map(\.rawValue),
            ],
            "idempotency_key": ["type": "string", "maxLength": 512],
        ]
        switch name {
        case "runtime.capabilities":
            return object([:], required: [])
        case "process.run":
            return object(common.merging([
                "executable": string,
                "arguments": [
                    "type": "array", "maxItems": 256, "items": string,
                ] as [String: Any],
            ]) { _, new in new }, required: ["executable", "replay_class"])
        case "shell.run", "bash.run", "python.run", "powershell.run":
            return object(common.merging([
                "script": ["type": "string", "maxLength": 1_048_576] as [String: Any],
            ]) { _, new in new }, required: ["script", "replay_class"])
        case "job.status", "job.cancel":
            return object(["job_id": string], required: ["job_id"])
        case "job.read_output":
            return object([
                "job_id": string,
                "stream": ["type": "string", "enum": RuntimeOutputStream.allCases.map(\.rawValue)],
                "offset": ["type": "integer", "minimum": 0],
                "limit": ["type": "integer", "minimum": 1, "maximum": 65_536],
            ], required: ["job_id"])
        case "job.list":
            return object([
                "states": [
                    "type": "array", "maxItems": RuntimeJobState.allCases.count,
                    "items": ["type": "string", "enum": RuntimeJobState.allCases.map(\.rawValue)],
                ] as [String: Any],
                "limit": ["type": "integer", "minimum": 1, "maximum": RuntimeJobRepository.maximumListLimit],
                "before_created_at": string,
            ], required: [])
        default:
            return nil
        }
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) async -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        do {
            try Self.requireAuthorization(name, context: context)
            switch name {
            case "runtime.capabilities":
                return .success(Self.capabilitiesPayload(await service.capabilities()))
            case "process.run", "shell.run", "bash.run", "python.run", "powershell.run":
                let request = try Self.request(name: name, arguments: arguments, context: context)
                let jobID = try await service.submit(request)
                return .success([
                    "job_id": jobID.uuidString.lowercased(),
                    "state": RuntimeJobState.queued.rawValue,
                    "project_id": context.projectID.description,
                    "project_generation": context.projectGeneration.rawValue,
                ])
            case "job.status":
                let jobID = try Self.jobID(arguments)
                return .success(Self.recordPayload(try await service.status(jobID: jobID, context: context)))
            case "job.read_output":
                let jobID = try Self.jobID(arguments)
                let stream = try Self.outputStream(arguments)
                let offset = try Self.nonnegativeUInt64(arguments, key: "offset", defaultValue: 0)
                let limit = ToolArgHelpers.int(arguments, "limit") ?? 16 * 1_024
                let slice = try await service.readOutput(
                    jobID: jobID,
                    stream: stream,
                    offset: offset,
                    limit: limit,
                    context: context
                )
                return .success([
                    "job_id": jobID.uuidString.lowercased(),
                    "stream": stream.rawValue,
                    "offset": slice.offset,
                    "data": String(decoding: slice.data, as: UTF8.self),
                    "next_offset": slice.nextOffset,
                    "retained_bytes": slice.totalRetainedBytes,
                    "observed_bytes": slice.totalObservedBytes,
                    "eof": slice.eof,
                    "artifact_truncated": slice.artifactTruncated,
                    "sha256": slice.sha256,
                ])
            case "job.cancel":
                let jobID = try Self.jobID(arguments)
                try await service.cancel(jobID: jobID, context: context)
                let record = try await service.status(jobID: jobID, context: context)
                return .success(Self.recordPayload(record))
            case "job.list":
                let states = try Self.states(arguments)
                let limit = ToolArgHelpers.int(arguments, "limit") ?? 20
                let records = try await service.list(
                    context: context,
                    states: states,
                    limit: limit,
                    beforeCreatedAt: ToolArgHelpers.string(arguments, "before_created_at")
                )
                return .success([
                    "jobs": records.map(Self.recordPayload),
                    "count": records.count,
                    "has_more": records.count == min(max(1, limit), RuntimeJobRepository.maximumListLimit),
                ])
            default:
                return nil
            }
        } catch let error as RuntimeJobError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: false)
        } catch let error as ProjectContextError {
            return .failure(
                code: error.code,
                message: error.localizedDescription,
                retryable: error == .databaseBusy
            )
        } catch {
            return .failure(code: "runtime_job_error", message: error.localizedDescription, retryable: false)
        }
    }

    private static func request(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> RuntimeJobRequest {
        let replayText = ToolArgHelpers.string(arguments, "replay_class")
        guard let replayText, let replayClass = RuntimeReplayClass(rawValue: replayText) else {
            throw RuntimeJobError.invalidRequest(
                "replay_class is required and must be read_only, idempotent, reconciled, or non_replayable"
            )
        }
        let cwd: URL
        if let value = ToolArgHelpers.string(arguments, "cwd") {
            cwd = ToolArgHelpers.resolvePath(value)
        } else if let root = context.authorizationScope.canonicalRoots.first {
            cwd = root
        } else {
            throw RuntimeJobError.invalidRequest("cwd is required when the project scope has no root")
        }
        let timeout = ToolArgHelpers.int(arguments, "timeout_sec") ?? 300
        let inline = ToolArgHelpers.int(arguments, "maximum_inline_output_bytes") ?? 64 * 1_024
        let idempotency = ToolArgHelpers.string(arguments, "idempotency_key")
        let kind: RuntimeKind
        let profile: RuntimeExecutionProfile
        let executable: URL?
        let argv: [String]
        let script: String?
        switch name {
        case "process.run":
            kind = .process
            profile = .directProcess
            guard let rawExecutable = ToolArgHelpers.string(arguments, "executable") else {
                throw RuntimeJobError.invalidRequest("executable is required")
            }
            executable = ToolArgHelpers.resolvePath(rawExecutable)
            argv = try stringArray(arguments, key: "arguments")
            script = nil
        case "shell.run":
            kind = .shell
            profile = .zshNoProfile
            executable = nil
            argv = []
            script = try requiredString(arguments, key: "script")
        case "bash.run":
            kind = .bash
            profile = .bashNoProfile
            executable = nil
            argv = []
            script = try requiredString(arguments, key: "script")
        case "python.run":
            kind = .python
            profile = .pythonIsolated
            executable = nil
            argv = []
            script = try requiredString(arguments, key: "script")
        case "powershell.run":
            kind = .powershell
            profile = .powershellNoProfile
            executable = nil
            argv = []
            script = try requiredString(arguments, key: "script")
        default:
            throw RuntimeJobError.invalidRequest("unsupported runtime submission tool")
        }
        return RuntimeJobRequest(
            kind: kind,
            profile: profile,
            context: context,
            executable: executable,
            arguments: argv,
            script: script,
            canonicalWorkingDirectory: cwd,
            timeout: .seconds(timeout),
            maximumInlineOutputBytes: inline,
            replayClass: replayClass,
            idempotencyKey: idempotency
        )
    }

    private static func requireAuthorization(_ name: String, context: ToolInvocationContext) throws {
        let allowed = context.authorizationScope.allowedTools
        guard allowed.contains(name) || allowed.contains("*") else {
            throw RuntimeJobError.unauthorizedTool(name)
        }
    }

    private static func jobID(_ arguments: [String: Any]) throws -> UUID {
        guard let value = ToolArgHelpers.string(arguments, "job_id"),
              let jobID = UUID(uuidString: value) else {
            throw RuntimeJobError.invalidRequest("job_id must be a UUID")
        }
        return jobID
    }

    private static func outputStream(_ arguments: [String: Any]) throws -> RuntimeOutputStream {
        let value = ToolArgHelpers.string(arguments, "stream") ?? RuntimeOutputStream.stdout.rawValue
        guard let stream = RuntimeOutputStream(rawValue: value) else {
            throw RuntimeJobError.invalidRequest("stream must be stdout or stderr")
        }
        return stream
    }

    private static func states(_ arguments: [String: Any]) throws -> Set<RuntimeJobState> {
        guard let raw = arguments["states"] else { return [] }
        guard let values = raw as? [String] else {
            throw RuntimeJobError.invalidRequest("states must be an array of runtime job state strings")
        }
        let decoded = values.compactMap(RuntimeJobState.init(rawValue:))
        guard decoded.count == values.count else {
            throw RuntimeJobError.invalidRequest("states contains an unsupported runtime job state")
        }
        return Set(decoded)
    }

    private static func nonnegativeUInt64(
        _ arguments: [String: Any],
        key: String,
        defaultValue: UInt64
    ) throws -> UInt64 {
        guard let raw = arguments[key] else { return defaultValue }
        if let number = raw as? NSNumber {
            let value = number.int64Value
            guard value >= 0 else { throw RuntimeJobError.invalidRequest("\(key) cannot be negative") }
            return UInt64(value)
        }
        if let text = raw as? String, let value = UInt64(text) { return value }
        throw RuntimeJobError.invalidRequest("\(key) must be a nonnegative integer")
    }

    private static func stringArray(_ arguments: [String: Any], key: String) throws -> [String] {
        guard let raw = arguments[key] else { return [] }
        guard let values = raw as? [String] else {
            throw RuntimeJobError.invalidRequest("\(key) must be an array of strings")
        }
        return values
    }

    private static func requiredString(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = ToolArgHelpers.string(arguments, key), !value.isEmpty else {
            throw RuntimeJobError.invalidRequest("\(key) is required")
        }
        return value
    }

    private static func capabilitiesPayload(_ capabilities: RuntimeCapabilities) -> [String: Any] {
        [
            "direct_process": capabilityPayload(capabilities.directProcess),
            "zsh": capabilityPayload(capabilities.zsh),
            "bash": capabilityPayload(capabilities.bash),
            "python": capabilityPayload(capabilities.python),
            "powershell": capabilityPayload(capabilities.powershell),
            "shell_available": capabilities.shellAvailable,
            "maximum_concurrent_jobs": capabilities.maximumConcurrentJobs,
            "maximum_cpu_heavy_jobs": capabilities.maximumCPUHeavyJobs,
            "maximum_inline_output_bytes": capabilities.maximumInlineOutputBytes,
            "maximum_artifact_bytes_per_job": capabilities.maximumArtifactBytesPerJob,
            "maximum_artifact_bytes_per_project": capabilities.maximumArtifactBytesPerProject,
            "maximum_artifact_bytes_global": capabilities.maximumArtifactBytesGlobal,
            "maximum_retained_artifact_jobs_per_project":
                capabilities.maximumRetainedArtifactJobsPerProject,
        ]
    }

    private static func capabilityPayload(_ capability: RuntimeExecutableCapability) -> [String: Any] {
        [
            "available": capability.available,
            "executable_path": capability.executablePath as Any,
            "required": capability.required,
        ]
    }

    private static func recordPayload(_ record: RuntimeJobRecord) -> [String: Any] {
        [
            "job_id": record.jobID.uuidString.lowercased(),
            "run_id": record.runID?.description as Any,
            "project_id": record.projectID.description,
            "project_generation": record.projectGeneration.rawValue,
            "runtime_kind": record.runtimeKind.rawValue,
            "execution_profile": record.executionProfile.rawValue,
            "replay_class": record.replayClass.rawValue,
            "state": record.state.rawValue,
            "cwd": record.canonicalWorkingDirectory.path,
            "command_summary": record.commandSummary,
            "timeout_seconds": record.timeoutSeconds,
            "exit_code": record.exitCode as Any,
            "output_artifact_id": record.outputArtifactID as Any,
            "output_bytes": record.outputBytes,
            "process_identifier": record.processIdentifier as Any,
            "process_group_identifier": record.processGroupIdentifier as Any,
            "error_code": record.errorCode as Any,
            "error_summary": record.errorSummary as Any,
            "created_at": record.createdAt,
            "started_at": record.startedAt as Any,
            "completed_at": record.completedAt as Any,
            "updated_at": record.updatedAt,
        ]
    }
}

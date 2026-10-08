// RuntimeJobToolPack.swift
// Async contextual tool surface for durable runtime jobs; registration is composed by the manager.

import Foundation

public protocol AsyncContextualToolPackHandling: Sendable {
    var toolNames: [String] { get }
    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) async throws -> ToolResult?
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
    private let postCancellationCommit: (@Sendable () async -> Void)?
    private let durableResultObserver: (@Sendable (ToolResult) -> Void)?
    private let preCommitAdmission: RuntimeJobPreCommitAdmission?

    public init(service: ExecutionJobService) {
        self.service = service
        postCancellationCommit = nil
        durableResultObserver = nil
        preCommitAdmission = nil
    }

    init(
        service: ExecutionJobService,
        postCancellationCommit: @escaping @Sendable () async -> Void
    ) {
        self.service = service
        self.postCancellationCommit = postCancellationCommit
        durableResultObserver = nil
        preCommitAdmission = nil
    }

    init(
        service: ExecutionJobService,
        preCommitAdmission: RuntimeJobPreCommitAdmission? = nil,
        durableResultObserver: @escaping @Sendable (ToolResult) -> Void
    ) {
        self.service = service
        postCancellationCommit = nil
        self.durableResultObserver = durableResultObserver
        self.preCommitAdmission = preCommitAdmission
    }

    public var toolNames: [String] { Self.names }

    public static func description(for name: String) -> String? {
        [
            "runtime.capabilities": "Report direct process and external runtime availability plus enforced job limits. Includes a bounded, service-startup filesystem inventory of optional executables and selected Python framework package assets when the inline result budget permits. Presence is limited to the reported search scope; probe_state=not_run, workflow_verified=false and import_verified=false do not establish working accounts, daemons, installs or imports. Unsupported package layouts are unknown. Restart the runtime service to refresh the cached inventory.",
            "process.run": "Start a durable direct executable/argument-vector job without shell parsing.",
            "shell.run": "Start a durable staged zsh job with startup files disabled.",
            "bash.run": "Start a durable staged Bash job with profile and rc files disabled.",
            "python.run": "Start a durable isolated Python job when the configured interpreter is available.",
            "powershell.run": "Start a durable noninteractive PowerShell job when pwsh is available.",
            "job.status": "Read durable status for one project-generation-bound runtime job.",
            "job.read_output": "Read a bounded stdout/stderr byte page, including an owned queued/running/cancelling snapshot. Continue at next_offset; pages may be shorter than limit to fit the result budget. For is_snapshot=true, retained_bytes, observed_bytes and sha256 describe the current snapshot; sha256_is_provisional=true and more bytes may arrive, so poll again at next_offset even when eof=true. job_state is the observed durable state. data is legacy text; optional data_base64 preserves exact bytes when the page is not valid UTF-8. eof ends retained byte pages only; producer_eof reports producer EOF separately. Complete native output requires a terminal job, is_snapshot=false, producer_end_reason=eof, producer_read_errno=null, and artifact_truncated=false for both streams. Missing/null producer reason is legacy unknown; read_error or forced_close is incomplete.",
            "job.cancel": "Cancel a runtime job and terminate its process group with bounded escalation.",
            "job.list": "List complete runtime job rows within the current project generation and inline result budget. Pass both fields from next_cursor to read the next page, including jobs with the same creation timestamp.",
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
                "before_job_id": ["type": "string", "minLength": 36, "maxLength": 36],
            ], required: [])
        default:
            return nil
        }
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) async throws -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        do {
            try Task.checkCancellation()
            try Self.requireAuthorization(name, context: context)
            switch name {
            case "runtime.capabilities":
                let capabilities = await service.capabilities()
                try Task.checkCancellation()
                return try Self.capabilitiesResult(
                    capabilities, budget: context.authorizationScope.maximumInlineOutputBytes
                )
            case "process.run", "shell.run", "bash.run", "python.run", "powershell.run":
                let request = try Self.request(
                    name: name,
                    arguments: arguments,
                    context: context,
                    preCommitAdmission: preCommitAdmission,
                    didPersist: { record in
                        durableResultObserver?(.success(Self.submissionPayload(record)))
                    }
                )
                try Task.checkCancellation()
                let jobID = try await service.submit(request)
                return .success(Self.submissionPayload(
                    jobID: jobID,
                    state: .queued,
                    context: context
                ))
            case "job.status":
                let jobID = try Self.jobID(arguments)
                let record = try await service.status(jobID: jobID, context: context)
                try Task.checkCancellation()
                return .success(Self.recordPayload(record))
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
                try Task.checkCancellation()
                return try Self.outputResult(slice, context: context)
            case "job.cancel":
                let jobID = try Self.jobID(arguments)
                let record = try await service.cancelAndReturnRecord(
                    jobID: jobID,
                    context: context,
                    commitObserver: { record in
                        durableResultObserver?(.success(Self.recordPayload(record)))
                    }
                )
                await postCancellationCommit?()
                // requestCancellation returns the row captured at its durable commit
                // boundary, so a late caller cancellation cannot conceal the result or
                // require an unowned follow-up read task.
                return .success(Self.recordPayload(record))
            case "job.list":
                let states = try Self.states(arguments)
                let limit = ToolArgHelpers.int(arguments, "limit") ?? 20
                let beforeJobID: UUID?
                if let value = arguments["before_job_id"] {
                    guard let raw = value as? String, let id = UUID(uuidString: raw) else {
                        throw RuntimeJobError.invalidRequest("before_job_id must be a UUID")
                    }
                    beforeJobID = id
                } else {
                    beforeJobID = nil
                }
                let records = try await service.list(
                    context: context,
                    states: states,
                    limit: limit,
                    beforeCreatedAt: ToolArgHelpers.string(arguments, "before_created_at"),
                    beforeJobID: beforeJobID
                )
                try Task.checkCancellation()
                return try Self.listResult(records, requestedLimit: limit, context: context)
            default:
                return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeJobError {
            let retryable: Bool
            if case .outputPending = error { retryable = true } else { retryable = false }
            return .failure(code: error.code, message: error.localizedDescription, retryable: retryable)
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

    private static func outputResult(
        _ slice: RuntimeOutputSlice,
        context: ToolInvocationContext
    ) throws -> ToolResult {
        let budget = min(ToolInvocationBroker.maximumDurableResultBytes,
                         context.authorizationScope.maximumInlineOutputBytes)
        // One verified read supplies every candidate. Every returned candidate
        // is checked against the complete durable result, including its wrapper.
        func candidate(_ count: Int) throws -> ToolResult? {
            try Task.checkCancellation()
            let bytes = Data(slice.data.prefix(count))
            let advanced = slice.offset.addingReportingOverflow(UInt64(count))
            let next = min(slice.totalRetainedBytes, advanced.overflow ? UInt64.max : advanced.partialValue)
            var payload: [String: Any] = [
                "job_id": slice.jobID.uuidString.lowercased(),
                "stream": slice.stream.rawValue,
                "offset": slice.offset,
                "data": String(decoding: bytes, as: UTF8.self),
                "next_offset": next,
                "retained_bytes": slice.totalRetainedBytes,
                "observed_bytes": slice.totalObservedBytes,
                "eof": next >= slice.totalRetainedBytes,
                "artifact_truncated": slice.artifactTruncated,
                "sha256": slice.sha256,
                "producer_end_reason": slice.producerEndReason?.rawValue as Any? ?? NSNull(),
                "producer_read_errno": slice.producerReadErrno as Any? ?? NSNull(),
                "is_snapshot": slice.isSnapshot,
                "sha256_is_provisional": slice.isSnapshot,
                "job_state": slice.jobState?.rawValue as Any? ?? NSNull(),
                "producer_eof": slice.producerEndReason == .eof,
            ]
            if String(data: bytes, encoding: .utf8) == nil {
                payload["data_base64"] = bytes.base64EncodedString()
            }
            let result = ToolResult.success(payload)
            let encoded = try JSONSupport.canonicalJSON([
                "ok": result.ok, "is_error": result.isError, "payload": result.payload,
            ])
            return encoded.utf8.count <= budget ? result : nil
        }
        var count = slice.data.count
        var rejectedCount: Int?
        for _ in 0..<18 {
            guard count > 0 || slice.data.isEmpty else {
                throw RuntimeJobError.invalidRequest("output byte page cannot fit the caller's inline result budget")
            }
            if var fitting = try candidate(count) {
                var lower = count
                var upper = (rejectedCount ?? count) - 1
                // Refine the verified fitting prefix so repeated small-budget
                // reads do not waste half their capacity. UTF-8 boundaries can
                // remove the base64 field; no unchecked size estimate is returned.
                for _ in 0..<16 where lower < upper {
                    let middle = lower + (upper - lower + 1) / 2
                    if let larger = try candidate(middle) {
                        fitting = larger
                        lower = middle
                    } else {
                        upper = middle - 1
                    }
                }
                return fitting
            }
            rejectedCount = count
            count /= 2
        }
        throw RuntimeJobError.invalidRequest("output page metadata exceeds the caller's inline result budget")
    }

    private static func listResult(
        _ records: [RuntimeJobRecord], requestedLimit: Int, context: ToolInvocationContext
    ) throws -> ToolResult {
        let budget = min(ToolInvocationBroker.maximumDurableResultBytes,
                         context.authorizationScope.maximumInlineOutputBytes)
        let mayHaveMore = records.count == min(max(1, requestedLimit), RuntimeJobRepository.maximumListLimit)
        func candidate(_ count: Int) throws -> ToolResult? {
            try Task.checkCancellation()
            let selected = records.prefix(count)
            let hasMore = count < records.count || mayHaveMore
            var payload: [String: Any] = [
                "jobs": selected.map(Self.recordPayload), "count": count, "has_more": hasMore,
            ]
            if hasMore, let last = selected.last {
                payload["next_cursor"] = [
                    "before_created_at": last.createdAt,
                    "before_job_id": last.jobID.uuidString.lowercased(),
                ]
            }
            let result = ToolResult.success(payload)
            let encoded = try JSONSupport.canonicalJSON([
                "ok": result.ok, "is_error": result.isError, "payload": result.payload,
            ])
            return encoded.utf8.count <= budget ? result : nil
        }
        if records.isEmpty, let empty = try candidate(0) { return empty }
        var lower = 0
        var upper = records.count
        var fitting: ToolResult?
        for _ in 0..<7 where lower < upper {
            let middle = lower + (upper - lower + 1) / 2
            if let result = try candidate(middle) {
                fitting = result
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        guard let fitting else {
            throw RuntimeJobError.invalidRequest("a complete job row cannot fit the caller's inline result budget")
        }
        return fitting
    }

    private static func request(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext,
        preCommitAdmission: RuntimeJobPreCommitAdmission? = nil,
        didPersist: (@Sendable (RuntimeJobRecord) -> Void)? = nil
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
            if rawExecutable.contains("/") {
                executable = ToolArgHelpers.resolvePath(rawExecutable)
            } else if let resolved = ProcessRunner.which(rawExecutable) {
                executable = URL(fileURLWithPath: resolved)
            } else {
                throw RuntimeJobError.executableUnavailable(rawExecutable)
            }
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
            idempotencyKey: idempotency,
            preCommitAdmission: preCommitAdmission,
            persistenceObserver: didPersist ?? { _ in }
        )
    }

    private static func submissionPayload(_ record: RuntimeJobRecord) -> [String: Any] {
        [
            "job_id": record.jobID.uuidString.lowercased(),
            "state": record.state.rawValue,
            "project_id": record.projectID.description,
            "project_generation": record.projectGeneration.rawValue,
        ]
    }

    private static func submissionPayload(
        jobID: UUID,
        state: RuntimeJobState,
        context: ToolInvocationContext
    ) -> [String: Any] {
        [
            "job_id": jobID.uuidString.lowercased(),
            "state": state.rawValue,
            "project_id": context.projectID.description,
            "project_generation": context.projectGeneration.rawValue,
        ]
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

    static func capabilitiesResult(_ capabilities: RuntimeCapabilities, budget: Int) throws -> ToolResult {
        let boundedBudget = min(ToolInvocationBroker.maximumDurableResultBytes, budget)
        let core = capabilitiesPayload(capabilities)
        func fits(_ payload: [String: Any]) throws -> Bool {
            // Correlation IDs are transport metadata. Stdio accepts unbounded
            // IDs within its request envelope; this bounds the duplicated result.
            try MCPToolResponse.data(id: nil, result: .success(payload)).count <= boundedBudget
        }
        var payload = core
        if let inventory = capabilities.inventory {
            payload["inventory"] = inventoryPayload(inventory)
            payload["inventory_status"] = "included"
            if try fits(payload) { return .success(payload) }
            payload = core
            payload["inventory_status"] = "omitted_inline_budget"
        } else {
            payload["inventory_status"] = "unavailable"
        }
        if try fits(payload) { return .success(payload) }
        // Preserve a legacy result that fits at the exact old metadata boundary.
        if try fits(core) { return .success(core) }
        throw RuntimeJobError.invalidRequest("runtime capability core metadata exceeds the inline result budget")
    }

    private static func inventoryPayload(_ inventory: RuntimeCapabilityInventory) -> [String: Any] {
        [
            "version": 1,
            "captured_at": inventory.capturedAt,
            "refresh_policy": "service_restart",
            "executable_search_scope": "bounded_absolute_path_and_standard_locations",
            "executable_search_complete": inventory.executableSearchComplete,
            "python_asset_search_scope": inventory.pythonAssetSearchScope.rawValue,
            "parent_runtime_status": inventory.parentRuntimeStatus.rawValue,
            "executables": inventory.executables.map { entry -> [String: Any] in
                [
                    "id": entry.id, "presence": entry.presence.rawValue,
                    "executable_path": entry.executablePath as Any? ?? NSNull(),
                    "executable": entry.executable as Any? ?? NSNull(),
                    "probe_state": "not_run", "workflow_verified": false,
                ]
            },
            "python_package_assets": inventory.pythonPackageAssets.map { entry -> [String: Any] in
                [
                    "id": entry.id, "module_name": entry.moduleName,
                    "presence": entry.presence.rawValue,
                    "asset_path": entry.assetPath as Any? ?? NSNull(),
                    "evidence": "filesystem_package_asset", "import_verified": false,
                ]
            },
        ]
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
            "status": capability.probeState.rawValue,
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

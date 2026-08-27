// ToolInvocationBroker.swift
// Persists classified tool side-effect intent before dispatch and reconciles replay safely.

import Foundation

public struct BrokeredToolCall: @unchecked Sendable {
    public let providerCallID: String
    public let toolName: String
    public let arguments: [String: Any]
    public let idempotencyKey: String?

    public init(
        providerCallID: String,
        toolName: String,
        arguments: [String: Any],
        idempotencyKey: String? = nil
    ) {
        self.providerCallID = providerCallID
        self.toolName = toolName
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
    }
}

public protocol ToolReplayClassifying: Sendable {
    func replayClass(for toolName: String) throws -> ToolReplayClass
}

public struct StaticToolReplayClassifier: ToolReplayClassifying, Sendable {
    private let classifications: [String: ToolReplayClass]

    public init(classifications: [String: ToolReplayClass]) {
        self.classifications = classifications
    }

    /// Production composition uses this initializer with `ToolRouter.toolNames`. It
    /// rejects both missing and stale classifications before any managed run starts.
    public init(
        productionToolNames: [String],
        classifications: [String: ToolReplayClass]
    ) throws {
        let names = Set(productionToolNames)
        guard !names.isEmpty, names.count == productionToolNames.count,
              names == Set(classifications.keys) else {
            throw AutonomyError.invalidRequest(
                "production tool replay classifications must exactly cover the registered tool set"
            )
        }
        self.classifications = classifications
    }

    public func replayClass(for toolName: String) throws -> ToolReplayClass {
        guard let value = classifications[toolName] else {
            throw AutonomyError.replayClassificationRequired(toolName)
        }
        return value
    }
}

/// Exact replay policy for the production `ToolRouter` surface. Construction must
/// pass the live router names so additions and removals fail before managed work starts.
public enum ProductionToolReplayCatalog {
    /// These tool contracts accept an idempotency key that reaches their durable
    /// subsystem. Managed provider calls receive the broker's stable call identity
    /// when the provider did not supply a key itself.
    public static let acceptsDurableIdempotencyArgument: Set<String> = [
        "continuity.checkpoint",
        "continuity.prepare_handoff",
        "continuity.request_rollover",
        "process.run",
        "shell.run",
        "bash.run",
        "python.run",
        "powershell.run",
        "project_memory.initialize",
        "project_memory.remember",
    ]

    public static let classifications: [String: ToolReplayClass] = [
        "forge_status": .readOnly,
        "agent_list": .readOnly,
        "agent_get": .readOnly,
        "agent_context": .readOnly,
        "agent_recommend": .readOnly,
        "agent_run_start": .nonReplayable,
        "agent_run_status": .readOnly,
        "agent_run_complete": .reconciled,

        "session_checkpoint": .reconciled,
        "session_handoff": .reconciled,
        "context_get": .idempotent,
        "context_list": .readOnly,

        "fs_read": .readOnly,
        "fs_write": .idempotent,
        "fs_edit": .reconciled,
        "fs_list": .readOnly,
        "fs_glob": .readOnly,
        "fs_mkdir": .idempotent,
        "fs_delete": .reconciled,
        "fs_move": .reconciled,

        "git_status": .readOnly,
        "git_diff": .readOnly,
        "git_log": .readOnly,
        "git_add": .reconciled,
        "git_commit": .reconciled,

        "pdf_write": .idempotent,
        "pdf_from_file": .idempotent,
        "search_text": .readOnly,

        "memory_set": .idempotent,
        "memory_get": .readOnly,
        "memory_list": .readOnly,
        "memory_delete": .idempotent,
        "memory_search": .readOnly,

        "project_memory.initialize": .idempotent,
        "project_memory.remember": .idempotent,
        "project_memory.remember_batch": .idempotent,
        "project_memory.search": .readOnly,
        "project_memory.get": .readOnly,
        "project_memory.update": .reconciled,
        "project_memory.forget": .idempotent,
        "project_memory.list_recent": .readOnly,
        "project_memory.link": .idempotent,
        "project_memory.export": .reconciled,
        "project_memory.import": .reconciled,
        "project_memory.status": .readOnly,

        "continuity.checkpoint": .reconciled,
        "continuity.prepare_handoff": .reconciled,
        "continuity.request_rollover": .reconciled,
        "continuity.get_pending_handoff": .readOnly,
        "continuity.acknowledge_handoff": .idempotent,
        "continuity.resume": .idempotent,
        "continuity.status": .readOnly,

        "runtime.capabilities": .readOnly,
        "process.run": .reconciled,
        "shell.run": .reconciled,
        "bash.run": .reconciled,
        "python.run": .reconciled,
        "powershell.run": .reconciled,
        "job.status": .readOnly,
        "job.read_output": .readOnly,
        "job.cancel": .idempotent,
        "job.list": .readOnly,
        "shell_exec": .nonReplayable,
    ]

    public static func classifier(
        productionToolNames: [String]
    ) throws -> StaticToolReplayClassifier {
        try StaticToolReplayClassifier(
            productionToolNames: productionToolNames,
            classifications: classifications
        )
    }

    public static func classification(for toolName: String) -> ToolReplayClass? {
        classifications[toolName]
    }
}

public enum ToolReconciliationOutcome: @unchecked Sendable {
    case completed(ToolResult)
    case safeToExecute
    case unresolved
}

public protocol ToolInvocationReconciling: Sendable {
    func prepare(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> String?

    func reconcile(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> ToolReconciliationOutcome
}

public extension ToolInvocationReconciling {
    func prepare(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> String? {
        nil
    }
}

public struct NoToolInvocationReconciler: ToolInvocationReconciling, Sendable {
    public init() {}

    public func reconcile(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> ToolReconciliationOutcome {
        .unresolved
    }
}

/// Production reconciliation uses durable subsystem receipts and bounded, hashed
/// preconditions captured before dispatch. A reconciled effect is repeated only when
/// the exact precondition is still present; otherwise it must have a verifiable
/// postcondition or remain blocked for operator review.
public struct ProductionToolInvocationReconciler: ToolInvocationReconciling, Sendable {
    private static let descriptorVersion = 1
    private static let maximumSnapshotBytes = 2 * 1_024 * 1_024
    private static let maximumGitOutputBytes = 64 * 1_024

    private let controlPlane: ProjectControlPlaneRepository
    private let runtimeJobs: RuntimeJobRepository
    private let memory: ProjectMemoryService

    public init(
        controlPlane: ProjectControlPlaneRepository,
        runtimeJobs: RuntimeJobRepository,
        memory: ProjectMemoryService
    ) {
        self.controlPlane = controlPlane
        self.runtimeJobs = runtimeJobs
        self.memory = memory
    }

    public func prepare(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> String? {
        switch call.toolName {
        case "fs_edit", "fs_delete", "fs_move":
            return try filesystemDescriptor(call: call, context: context)
        case "git_add", "git_commit":
            return try gitDescriptor(call: call, context: context)
        case "project_memory.update":
            return try projectMemoryUpdateDescriptor(call: call, context: context)
        default:
            return nil
        }
    }

    public func reconcile(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> ToolReconciliationOutcome {
        guard invocation.toolName == call.toolName,
              invocation.projectID == context.projectID,
              invocation.projectGeneration == context.projectGeneration,
              invocation.runID == context.runID else {
            return .unresolved
        }
        switch call.toolName {
        case "process.run", "shell.run", "bash.run", "python.run", "powershell.run":
            return try await reconcileRuntimeSubmission(call: call, context: context)
        case "fs_edit", "fs_delete", "fs_move":
            return try reconcileFilesystem(
                invocation: invocation,
                call: call,
                context: context
            )
        case "git_add", "git_commit":
            return try reconcileGit(
                invocation: invocation,
                call: call,
                context: context
            )
        case "continuity.checkpoint", "continuity.prepare_handoff",
             "continuity.request_rollover":
            return try await reconcileContinuity(call: call, context: context)
        case "project_memory.update":
            return try reconcileProjectMemoryUpdate(
                invocation: invocation,
                call: call,
                context: context
            )
        case "agent_run_complete", "session_checkpoint", "session_handoff",
             "project_memory.export", "project_memory.import":
            // These contracts have no provider-call-keyed receipt or complete
            // postcondition. Repeating them could finalize a changed session or
            // export/import a different snapshot, so ambiguity remains explicit.
            return .unresolved
        default:
            return .unresolved
        }
    }

    private func reconcileRuntimeSubmission(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> ToolReconciliationOutcome {
        guard let key = Self.string(call.arguments, "idempotency_key"), !key.isEmpty else {
            return .unresolved
        }
        guard let record = try await runtimeJobs.existingJob(
            projectID: context.projectID,
            generation: context.projectGeneration,
            idempotencyKey: key
        ) else {
            // Submission is safe because the same key is passed to the runtime
            // repository, whose unique project-generation receipt is authoritative.
            return .safeToExecute
        }
        guard record.runID == context.runID,
              record.idempotencyKey == key else {
            return .unresolved
        }
        return .completed(.success([
            "job_id": record.jobID.uuidString.lowercased(),
            "state": record.state.rawValue,
            "project_id": record.projectID.description,
            "project_generation": record.projectGeneration.rawValue,
        ]))
    }

    private func filesystemDescriptor(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> String? {
        switch call.toolName {
        case "fs_edit":
            guard let rawPath = Self.string(call.arguments, "path"),
                  let path = Self.authorizedURL(rawPath, context: context),
                  let old = Self.string(call.arguments, "old"),
                  let new = Self.string(call.arguments, "new"),
                  !old.isEmpty,
                  let data = Self.regularFileData(path),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let replacements = text.components(separatedBy: old).count - 1
            guard replacements > 0 else { return nil }
            let post = Data(text.replacingOccurrences(of: old, with: new).utf8)
            return try Self.descriptor([
                "tool": call.toolName,
                "path_sha256": JSONSupport.sha256Hex(path.path),
                "pre_sha256": JSONSupport.sha256Hex(data),
                "post_sha256": JSONSupport.sha256Hex(post),
                "post_bytes": post.count,
                "replacements": replacements,
            ])
        case "fs_delete":
            guard let rawPath = Self.string(call.arguments, "path"),
                  let path = Self.authorizedURL(rawPath, context: context) else {
                return nil
            }
            guard FileManager.default.fileExists(atPath: path.path) else {
                return try Self.descriptor([
                    "tool": call.toolName,
                    "path_sha256": JSONSupport.sha256Hex(path.path),
                    "precondition": "missing",
                ])
            }
            guard let data = Self.regularFileData(path) else { return nil }
            return try Self.descriptor([
                "tool": call.toolName,
                "path_sha256": JSONSupport.sha256Hex(path.path),
                "pre_sha256": JSONSupport.sha256Hex(data),
                "pre_bytes": data.count,
            ])
        case "fs_move":
            guard let rawSource = Self.string(call.arguments, "path")
                    ?? Self.string(call.arguments, "src")
                    ?? Self.string(call.arguments, "source"),
                  let rawDestination = Self.string(call.arguments, "dest")
                    ?? Self.string(call.arguments, "destination"),
                  let source = Self.authorizedURL(rawSource, context: context),
                  let destination = Self.authorizedURL(rawDestination, context: context),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let data = Self.regularFileData(source) else {
                return nil
            }
            return try Self.descriptor([
                "tool": call.toolName,
                "source_sha256": JSONSupport.sha256Hex(source.path),
                "destination_sha256": JSONSupport.sha256Hex(destination.path),
                "content_sha256": JSONSupport.sha256Hex(data),
                "bytes": data.count,
            ])
        default:
            return nil
        }
    }

    private func reconcileFilesystem(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> ToolReconciliationOutcome {
        guard let descriptor = Self.descriptorObject(
            invocation.reconciliationDescriptor,
            toolName: call.toolName
        ) else {
            return .unresolved
        }
        switch call.toolName {
        case "fs_edit":
            guard let rawPath = Self.string(call.arguments, "path"),
                  let path = Self.authorizedURL(rawPath, context: context),
                  descriptor["path_sha256"] as? String == JSONSupport.sha256Hex(path.path),
                  let data = Self.regularFileData(path),
                  let pre = descriptor["pre_sha256"] as? String,
                  let post = descriptor["post_sha256"] as? String else {
                return .unresolved
            }
            let current = JSONSupport.sha256Hex(data)
            if current == post {
                return .completed(.success([
                    "path": path.path,
                    "replacements": Self.integer(descriptor["replacements"]) ?? 0,
                ]))
            }
            return current == pre ? .safeToExecute : .unresolved
        case "fs_delete":
            guard let rawPath = Self.string(call.arguments, "path"),
                  let path = Self.authorizedURL(rawPath, context: context),
                  descriptor["path_sha256"] as? String == JSONSupport.sha256Hex(path.path) else {
                return .unresolved
            }
            guard FileManager.default.fileExists(atPath: path.path) else {
                return .completed(.success(["path": path.path, "deleted": true]))
            }
            guard let pre = descriptor["pre_sha256"] as? String,
                  let data = Self.regularFileData(path) else {
                return .unresolved
            }
            return JSONSupport.sha256Hex(data) == pre ? .safeToExecute : .unresolved
        case "fs_move":
            guard let rawSource = Self.string(call.arguments, "path")
                    ?? Self.string(call.arguments, "src")
                    ?? Self.string(call.arguments, "source"),
                  let rawDestination = Self.string(call.arguments, "dest")
                    ?? Self.string(call.arguments, "destination"),
                  let source = Self.authorizedURL(rawSource, context: context),
                  let destination = Self.authorizedURL(rawDestination, context: context),
                  descriptor["source_sha256"] as? String == JSONSupport.sha256Hex(source.path),
                  descriptor["destination_sha256"] as? String
                    == JSONSupport.sha256Hex(destination.path),
                  let expected = descriptor["content_sha256"] as? String else {
                return .unresolved
            }
            let sourceData = Self.regularFileData(source)
            let destinationData = Self.regularFileData(destination)
            if sourceData == nil,
               let destinationData,
               JSONSupport.sha256Hex(destinationData) == expected {
                return .completed(.success([
                    "src": source.path,
                    "dest": destination.path,
                ]))
            }
            if destinationData == nil,
               let sourceData,
               JSONSupport.sha256Hex(sourceData) == expected {
                return .safeToExecute
            }
            return .unresolved
        default:
            return .unresolved
        }
    }

    private func gitDescriptor(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> String? {
        guard let cwd = Self.gitWorkingDirectory(call: call, context: context),
              let snapshot = Self.gitSnapshot(cwd: cwd) else {
            return nil
        }
        var value: [String: Any] = [
            "tool": call.toolName,
            "cwd_sha256": JSONSupport.sha256Hex(cwd.path),
            "head": snapshot.head,
            "index_sha256": snapshot.indexSHA256,
            "status_sha256": snapshot.statusSHA256,
        ]
        if call.toolName == "git_commit" {
            value["message_sha256"] = JSONSupport.sha256Hex(
                Self.string(call.arguments, "message")
                    ?? "chore: forge-conductor commit"
            )
        }
        return try Self.descriptor(value)
    }

    private func reconcileGit(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> ToolReconciliationOutcome {
        guard let descriptor = Self.descriptorObject(
            invocation.reconciliationDescriptor,
            toolName: call.toolName
        ), let cwd = Self.gitWorkingDirectory(call: call, context: context),
           descriptor["cwd_sha256"] as? String == JSONSupport.sha256Hex(cwd.path),
           let beforeHead = descriptor["head"] as? String,
           let beforeIndex = descriptor["index_sha256"] as? String,
           let beforeStatus = descriptor["status_sha256"] as? String,
           let current = Self.gitSnapshot(cwd: cwd) else {
            return .unresolved
        }
        let unchanged = current.head == beforeHead
            && current.indexSHA256 == beforeIndex
            && current.statusSHA256 == beforeStatus
        if call.toolName == "git_add" {
            // Re-execution is permitted only while HEAD, index, worktree, and
            // untracked-file state are byte-for-byte the captured precondition.
            // A post-add index cannot be derived without mutating Git's object store,
            // so a completed-but-unrecorded add stays unresolved.
            return unchanged ? .safeToExecute : .unresolved
        }
        guard call.toolName == "git_commit",
              let messageSHA256 = descriptor["message_sha256"] as? String else {
            return .unresolved
        }
        if unchanged { return .safeToExecute }
        guard !current.head.isEmpty,
              current.indexSHA256 == Self.gitTreeManifestSHA(cwd: cwd, revision: current.head),
              current.indexSHA256 == beforeIndex,
              Self.gitCommitHasExpectedParent(
                cwd: cwd,
                revision: current.head,
                expectedParent: beforeHead
              ),
              Self.gitCommitMessage(cwd: cwd, revision: current.head).map(
                JSONSupport.sha256Hex
              ) == messageSHA256 else {
            return .unresolved
        }
        return .completed(.success([
            "ok": true,
            "exit_code": 0,
            "stdout": "Reconciled commit \(String(current.head.prefix(12)))\n",
            "stderr": "",
            "cwd": cwd.path,
        ]))
    }

    private func reconcileContinuity(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) async throws -> ToolReconciliationOutcome {
        let projectString = Self.string(call.arguments, "project_id")
            ?? context.projectID.description
        guard projectString.caseInsensitiveCompare(context.projectID.description) == .orderedSame else {
            return .unresolved
        }
        let repository = try memory.repositoryForProject(context.projectID.description)
        let operationID = Self.string(call.arguments, "operation_id")?.lowercased()
        let key = Self.string(call.arguments, "idempotency_key")
        let operationV2: ContinuityOperationV2?
        if let operationID {
            operationV2 = try repository.continuityOperationV2(id: operationID)
        } else if let key {
            operationV2 = try repository.continuityOperationV2(idempotencyKey: key)
        } else {
            operationV2 = nil
        }
        if var operation = operationV2 {
            if let operationID,
               operation.operationID.caseInsensitiveCompare(operationID) != .orderedSame {
                return .unresolved
            }
            guard let handoff = try repository.continuityHandoffV2(id: operation.handoffID),
                  Self.string(call.arguments, "handoff_id").map({
                    operation.handoffID.caseInsensitiveCompare($0) == .orderedSame
                  }) ?? true else {
                return .unresolved
            }
            if operation.state == .active || operation.state == .checkpointPreparing {
                operation = try ContinuityStateEngine(memory: memory).prepareV2(
                    handoff: handoff,
                    predecessorSessionID: operation.predecessorSessionID,
                    predecessorProviderResponseID: operation.predecessorProviderResponseID,
                    adapterID: operation.adapterID,
                    idempotencyKey: operation.idempotencyKey,
                    budgetObservationID: operation.budgetObservationID
                )
            }
            if call.toolName == "continuity.request_rollover",
               handoff.continuityMode == .managedAutonomous {
                guard let operationUUID = UUID(uuidString: operation.operationID) else {
                    return .unresolved
                }
                if let command = try await controlPlane.continuityCommand(
                    operationID: operationUUID
                ) {
                    return .completed(.success([
                        "disposition": "manager_operation_queued",
                        "request_route": "manager_command_queue",
                        "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                        "manager_operation_enqueued": true,
                        "session_creation_confirmed": false,
                        "operation_id": operation.operationID,
                        "command_id": command.commandID.uuidString.lowercased(),
                        "command": command.asDictionary(),
                        "operation": operation.asDictionary(),
                        "handoff": handoff.asDictionary(),
                        "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
                        "canonical_location": "project_local",
                        "global_latest_authority": false,
                    ]))
                }
                guard operation.state == .checkpointPersisted else {
                    return .unresolved
                }
                let command = try await ManagedContinuityCommandRouter(
                    memory: memory,
                    controlPlane: controlPlane
                ).request(
                    handoff: handoff,
                    predecessorSessionID: operation.predecessorSessionID,
                    predecessorProviderResponseID: operation.predecessorProviderResponseID,
                    adapterID: operation.adapterID,
                    idempotencyKey: operation.idempotencyKey,
                    requestedBy: Self.string(call.arguments, "requested_by")
                        ?? "continuity.request_rollover",
                    reason: Self.string(call.arguments, "reason")
                        ?? Self.string(call.arguments, "context_trigger")
                        ?? "managed rollover requested",
                    commandType: Self.string(call.arguments, "context_action") == "emergency"
                        ? .emergencyRollover
                        : .rollover,
                    budgetObservationID: operation.budgetObservationID
                )
                return .completed(.success([
                    "disposition": "manager_operation_queued",
                    "request_route": "manager_command_queue",
                    "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                    "manager_operation_enqueued": true,
                    "session_creation_confirmed": false,
                    "operation_id": operation.operationID,
                    "command_id": command.commandID.uuidString.lowercased(),
                    "command": command.asDictionary(),
                    "operation": operation.asDictionary(),
                    "handoff": handoff.asDictionary(),
                    "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
                    "canonical_location": "project_local",
                    "global_latest_authority": false,
                ]))
            }
            return .completed(.success(
                Self.continuityPayloadV2(
                    operation: operation,
                    handoff: handoff,
                    toolName: call.toolName
                )
            ))
        }

        let operationV1: ContinuityOperation?
        if let operationID {
            operationV1 = try repository.continuityOperation(id: operationID)
        } else if let key {
            operationV1 = try repository.continuityOperation(idempotencyKey: key)
        } else {
            operationV1 = nil
        }
        if var operation = operationV1,
           let handoff = try repository.continuityHandoff(id: operation.handoffID) {
            if operation.state == .active || operation.state == .checkpointPreparing {
                operation = try ContinuityStateEngine(memory: memory).prepare(
                    handoff: handoff,
                    predecessorSessionID: operation.predecessorSessionID,
                    adapterID: operation.adapterID,
                    idempotencyKey: operation.idempotencyKey
                )
            }
            return .completed(.success(
                Self.continuityPayloadV1(
                    operation: operation,
                    handoff: handoff,
                    toolName: call.toolName
                )
            ))
        }
        // No durable operation under the injected idempotency key means dispatch
        // never established a project-local side effect.
        return key?.isEmpty == false ? .safeToExecute : .unresolved
    }

    private func projectMemoryUpdateDescriptor(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> String? {
        guard let projectID = Self.trimmedString(call.arguments, "project_id"),
              projectID.caseInsensitiveCompare(context.projectID.description) == .orderedSame,
              let recordID = Self.trimmedString(call.arguments, "id"),
              let expectedVersion = Self.integer(call.arguments["expected_version"]),
              let record = try memory.repositoryForProject(projectID).get(
                id: recordID,
                includeTombstone: false
              ), record.version == expectedVersion else {
            return nil
        }
        let expectedTitle = try Self.expectedMemoryString(
            call.arguments,
            key: "title",
            current: record.title
        ) ?? record.title
        let expectedSummary = try Self.expectedMemoryString(
            call.arguments,
            key: "summary",
            current: record.summary
        ) ?? record.summary
        let expectedBody = try Self.expectedMemoryString(
            call.arguments,
            key: "body",
            current: record.body
        )
        let expectedTags = call.arguments["tags"] == nil
            ? record.tags
            : Self.normalizedMemoryTags(call.arguments["tags"])
        return try Self.descriptor([
            "tool": call.toolName,
            "project_id_sha256": JSONSupport.sha256Hex(context.projectID.description),
            "record_id_sha256": JSONSupport.sha256Hex(recordID),
            "expected_version": expectedVersion,
            "pre_content_sha256": record.contentHash,
            "expected_fields_sha256": try Self.memoryFieldSHA256(
                title: expectedTitle,
                summary: expectedSummary,
                body: expectedBody,
                tags: expectedTags
            ),
        ])
    }

    private func reconcileProjectMemoryUpdate(
        invocation: ToolInvocationRecord,
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) throws -> ToolReconciliationOutcome {
        guard let descriptor = Self.descriptorObject(
                invocation.reconciliationDescriptor,
                toolName: call.toolName
              ),
              let projectID = Self.trimmedString(call.arguments, "project_id"),
              projectID.caseInsensitiveCompare(context.projectID.description) == .orderedSame,
              descriptor["project_id_sha256"] as? String
                == JSONSupport.sha256Hex(context.projectID.description),
              let recordID = Self.trimmedString(call.arguments, "id"),
              descriptor["record_id_sha256"] as? String == JSONSupport.sha256Hex(recordID),
              let expectedVersion = Self.integer(call.arguments["expected_version"]),
              Self.integer(descriptor["expected_version"]) == expectedVersion,
              let preContentSHA256 = descriptor["pre_content_sha256"] as? String,
              let expectedFieldsSHA256 = descriptor["expected_fields_sha256"] as? String,
              let record = try memory.repositoryForProject(projectID).get(
                id: recordID,
                includeTombstone: false
              ) else {
            return .unresolved
        }
        if record.version == expectedVersion {
            return record.contentHash == preContentSHA256 ? .safeToExecute : .unresolved
        }
        guard record.version == expectedVersion + 1,
              try Self.memoryFieldSHA256(
                title: record.title,
                summary: record.summary,
                body: record.body,
                tags: record.tags
              ) == expectedFieldsSHA256 else {
            return .unresolved
        }
        return .completed(.success([
            "record": record.asDictionary(includeBody: true),
            "schema_version": ProjectMemoryRepository.schemaVersion,
        ]))
    }

    private static func continuityPayloadV2(
        operation: ContinuityOperationV2,
        handoff: ContinuityHandoffV2,
        toolName: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "disposition": "memory_only_handoff_ready",
            "operation_id": operation.operationID,
            "operation": operation.asDictionary(),
            "handoff": handoff.asDictionary(),
            "handoff_schema_version": ContinuityHandoffV2.schemaVersion,
            "canonical_location": "project_local",
            "global_latest_authority": false,
            "host_capability": "external_session_creation_unconfirmed",
            "session_creation_confirmed": false,
        ]
        switch toolName {
        case "continuity.checkpoint":
            payload["request_route"] = "checkpoint_only"
            payload["checkpoint_persisted"] = true
        case "continuity.prepare_handoff":
            payload["request_route"] = "prepare_handoff"
            payload["handoff_prepared"] = true
        default:
            payload["request_route"] = "external_handoff_only"
            payload["external_capability"] = "handoff_only"
            payload["manager_operation_enqueued"] = false
        }
        return payload
    }

    private static func continuityPayloadV1(
        operation: ContinuityOperation,
        handoff: ContinuityHandoff,
        toolName: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "disposition": "memory_only_handoff_ready",
            "operation": operation.asDictionary(),
            "handoff": handoff.asDictionary(),
            "host_capability": "external_session_creation_unconfirmed",
            "session_creation_confirmed": false,
        ]
        switch toolName {
        case "continuity.checkpoint":
            payload["request_route"] = "checkpoint_only"
            payload["checkpoint_persisted"] = true
        case "continuity.prepare_handoff":
            payload["request_route"] = "prepare_handoff"
            payload["handoff_prepared"] = true
        default:
            payload["request_route"] = "external_handoff_only"
            payload["external_capability"] = "handoff_only"
            payload["manager_operation_enqueued"] = false
        }
        return payload
    }

    private struct GitSnapshot {
        let head: String
        let indexSHA256: String
        let statusSHA256: String
    }

    private static func gitSnapshot(cwd: URL) -> GitSnapshot? {
        guard let inside = git(cwd: cwd, arguments: ["rev-parse", "--is-inside-work-tree"]),
              inside.exitCode == 0,
              inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              let status = git(
                cwd: cwd,
                arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
              ), status.exitCode == 0, !status.stdoutTruncated,
              let indexSHA256 = gitIndexManifestSHA(cwd: cwd) else {
            return nil
        }
        let headResult = git(cwd: cwd, arguments: ["rev-parse", "--verify", "HEAD"])
        let head = headResult?.exitCode == 0
            ? headResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        return GitSnapshot(
            head: head,
            indexSHA256: indexSHA256,
            statusSHA256: JSONSupport.sha256Hex(status.stdout)
        )
    }

    private static func gitIndexManifestSHA(cwd: URL) -> String? {
        guard let result = git(cwd: cwd, arguments: ["ls-files", "--stage", "-z"]),
              result.exitCode == 0, !result.stdoutTruncated else {
            return nil
        }
        var normalized = ""
        for entry in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let value = String(entry)
            guard let tab = value.firstIndex(of: "\t") else { return nil }
            let metadata = value[..<tab].split(separator: " ")
            guard metadata.count == 3, metadata[2] == "0" else { return nil }
            normalized += "\(metadata[0]) \(metadata[1])\t\(value[value.index(after: tab)...])\n"
        }
        return JSONSupport.sha256Hex(normalized)
    }

    private static func gitTreeManifestSHA(cwd: URL, revision: String) -> String? {
        guard let result = git(
            cwd: cwd,
            arguments: ["ls-tree", "-rz", "--full-tree", revision]
        ), result.exitCode == 0, !result.stdoutTruncated else {
            return nil
        }
        var normalized = ""
        for entry in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let value = String(entry)
            guard let tab = value.firstIndex(of: "\t") else { return nil }
            let metadata = value[..<tab].split(separator: " ")
            guard metadata.count == 3 else { return nil }
            normalized += "\(metadata[0]) \(metadata[2])\t\(value[value.index(after: tab)...])\n"
        }
        return JSONSupport.sha256Hex(normalized)
    }

    private static func gitCommitHasExpectedParent(
        cwd: URL,
        revision: String,
        expectedParent: String
    ) -> Bool {
        guard let result = git(
            cwd: cwd,
            arguments: ["rev-list", "--parents", "-n", "1", revision]
        ), result.exitCode == 0 else {
            return false
        }
        let values = result.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        if expectedParent.isEmpty { return values.count == 1 && values.first == revision }
        return values.count == 2 && values.first == revision && values[1] == expectedParent
    }

    private static func gitCommitMessage(cwd: URL, revision: String) -> String? {
        guard let result = git(
            cwd: cwd,
            arguments: ["log", "-1", "--format=%B", revision]
        ), result.exitCode == 0, !result.stdoutTruncated else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    private static func git(
        cwd: URL,
        arguments: [String]
    ) -> ProcessResult? {
        try? ProcessRunner().run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: cwd.path,
            timeoutSec: 5,
            maximumOutputBytes: maximumGitOutputBytes
        )
    }

    private static func gitWorkingDirectory(
        call: BrokeredToolCall,
        context: ToolInvocationContext
    ) -> URL? {
        if let raw = string(call.arguments, "cwd") {
            return authorizedURL(raw, context: context)
        }
        return context.authorizationScope.canonicalRoots.first.flatMap {
            authorizedURL($0.path, context: context)
        }
    }

    private static func descriptor(_ values: [String: Any]) throws -> String {
        var output = values
        output["descriptor_version"] = descriptorVersion
        return try JSONSupport.canonicalJSON(output)
    }

    private static func descriptorObject(
        _ value: String?,
        toolName: String
    ) -> [String: Any]? {
        guard let value, value.utf8.count <= 8_192,
              let data = value.data(using: .utf8),
              let object = try? JSONSupport.object(from: data),
              integer(object["descriptor_version"]) == descriptorVersion,
              object["tool"] as? String == toolName else {
            return nil
        }
        return object
    }

    private static func regularFileData(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ), values.isRegularFile == true,
           let size = values.fileSize,
           size <= maximumSnapshotBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func authorizedURL(
        _ raw: String,
        context: ToolInvocationContext
    ) -> URL? {
        guard let base = context.authorizationScope.canonicalRoots.first else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let unresolved = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : base.appendingPathComponent(expanded).standardizedFileURL
        var existing = unresolved
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var candidate = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { candidate.appendPathComponent(component) }
        candidate = candidate.standardizedFileURL
        let candidateComponents = candidate.pathComponents
        let authorized = context.authorizationScope.canonicalRoots.contains { rawRoot in
            let root = rawRoot.resolvingSymlinksInPath().standardizedFileURL
            let rootComponents = root.pathComponents
            return candidateComponents.count >= rootComponents.count
                && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        }
        return authorized ? candidate : nil
    }

    private static func string(_ arguments: [String: Any], _ key: String) -> String? {
        ToolArgHelpers.string(arguments, key)
    }

    private static func trimmedString(
        _ arguments: [String: Any],
        _ key: String
    ) -> String? {
        string(arguments, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expectedMemoryString(
        _ arguments: [String: Any],
        key: String,
        current: String?
    ) throws -> String? {
        guard arguments[key] != nil,
              let value = trimmedString(arguments, key) else {
            return current
        }
        return try ProjectMemoryRedactor().redact(value)
    }

    private static func normalizedMemoryTags(_ value: Any?) -> [String] {
        let raw: [String]
        if let values = value as? [String] {
            raw = values
        } else if let values = value as? [Any] {
            raw = values.compactMap { $0 as? String }
        } else if let value = value as? String {
            raw = [value]
        } else {
            raw = []
        }
        return Array(Set(raw.compactMap { item -> String? in
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? nil : normalized
        })).sorted()
    }

    private static func memoryFieldSHA256(
        title: String,
        summary: String,
        body: String?,
        tags: [String]
    ) throws -> String {
        JSONSupport.sha256Hex(try JSONSupport.canonicalJSON([
            "title": title,
            "summary": summary,
            "body": body.map { $0 as Any } ?? NSNull(),
            "tags": tags.sorted(),
        ]))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(exactly: value) }
        if let value = value as? NSNumber { return Int(exactly: value.doubleValue) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

public actor ToolInvocationBroker {
    public static let maximumDurableResultBytes = 64 * 1_024

    private let repository: ProjectControlPlaneRepository
    private let executor: any ToolExecuting
    private let classifier: any ToolReplayClassifying
    private let reconciler: any ToolInvocationReconciling

    public init(
        repository: ProjectControlPlaneRepository,
        executor: any ToolExecuting,
        classifier: any ToolReplayClassifying,
        reconciler: any ToolInvocationReconciling = NoToolInvocationReconciler()
    ) {
        self.repository = repository
        self.executor = executor
        self.classifier = classifier
        self.reconciler = reconciler
    }

    /// The invocation row is committed before the tool executor is entered. A provider
    /// call ID is a durable identity within its session, so retries must supply identical
    /// arguments and classification.
    public func invoke(
        _ incomingCall: BrokeredToolCall,
        turnID: UUID,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ToolResult {
        guard let runID = context.runID, runID == lease.runID,
              let sessionID = context.providerSessionID, !sessionID.isEmpty else {
            throw ProjectContextError.projectScopeMismatch
        }
        guard context.authorizationScope.allowedTools.contains(incomingCall.toolName)
                || context.authorizationScope.allowedTools.contains("*") else {
            throw AutonomyError.invalidRequest("tool is outside the run authorization scope")
        }
        let call = Self.durableCall(incomingCall)
        let replayClass = try classifier.replayClass(for: call.toolName)
        if replayClass == .idempotent,
           call.idempotencyKey?.isEmpty != false {
            throw AutonomyError.invalidRequest("idempotent tool calls require an idempotency key")
        }
        let argumentsJSON = try JSONSupport.canonicalJSON(call.arguments)
        guard argumentsJSON.utf8.count <= context.authorizationScope.maximumInlineOutputBytes,
              argumentsJSON.utf8.count <= Self.maximumDurableResultBytes else {
            throw AutonomyError.invalidRequest("tool arguments exceed the durable broker bound")
        }
        let argumentsSHA = JSONSupport.sha256Hex(argumentsJSON)
        let prior = try await repository.toolInvocation(
            sessionID: sessionID,
            providerCallID: call.providerCallID
        )
        let reconciliationDescriptor: String?
        if let prior {
            reconciliationDescriptor = prior.reconciliationDescriptor
        } else {
            reconciliationDescriptor = try await reconciler.prepare(
                call: call,
                context: context
            )
        }
        let intent = ToolInvocationIntent(
            invocationID: prior?.invocationID ?? UUID(),
            turnID: turnID,
            runID: runID,
            sessionID: sessionID,
            projectID: context.projectID,
            projectGeneration: context.projectGeneration,
            providerCallID: call.providerCallID,
            toolName: call.toolName,
            replayClass: replayClass,
            idempotencyKey: call.idempotencyKey,
            argumentsSHA256: argumentsSHA,
            reconciliationDescriptor: reconciliationDescriptor
        )
        var record = try await repository.persistToolInvocationIntent(intent, lease: lease)

        if record.state == .completed {
            return try Self.decodeResult(record.resultSummary)
        }

        switch record.state {
        case .intent:
            // A persisted descriptor is also a dispatch-time fence. Recheck it
            // after the intent commit so a filesystem or Git change in the
            // capture-to-commit window cannot be overwritten by first dispatch.
            if replayClass == .reconciled,
               prior != nil || record.reconciliationDescriptor != nil {
                switch try await reconciler.reconcile(
                    invocation: record,
                    call: call,
                    context: context
                ) {
                case .completed(let result):
                    return try await complete(
                        result,
                        record: record,
                        expectedState: .intent,
                        lease: lease,
                        context: context
                    )
                case .safeToExecute:
                    break
                case .unresolved:
                    throw AutonomyError.replayBlocked(.reconciled)
                }
            }
        case .executing:
            record = try await repository.transitionToolInvocation(
                invocationID: record.invocationID,
                expected: .executing,
                to: .ambiguous,
                lease: lease,
                errorCode: "manager_interrupted",
                errorSummary: "Tool execution was interrupted before a durable result was recorded"
            )
            fallthrough
        case .ambiguous, .failed:
            switch replayClass {
            case .readOnly, .idempotent:
                break
            case .reconciled:
                switch try await reconciler.reconcile(
                    invocation: record,
                    call: call,
                    context: context
                ) {
                case .completed(let result):
                    return try await complete(
                        result,
                        record: record,
                        expectedState: record.state,
                        lease: lease,
                        context: context
                    )
                case .safeToExecute:
                    break
                case .unresolved:
                    throw AutonomyError.replayBlocked(.reconciled)
                }
            case .nonReplayable:
                throw AutonomyError.replayBlocked(.nonReplayable)
            }
        case .completed:
            return try Self.decodeResult(record.resultSummary)
        case .cancelled, .quarantinedStale:
            throw AutonomyError.replayBlocked(replayClass)
        }

        let expectedState = record.state
        record = try await repository.transitionToolInvocation(
            invocationID: record.invocationID,
            expected: expectedState,
            to: .executing,
            lease: lease
        )
        do {
            let result = try executor.call(
                name: call.toolName,
                arguments: call.arguments,
                context: context
            )
            return try await complete(
                result,
                record: record,
                expectedState: .executing,
                lease: lease,
                context: context
            )
        } catch {
            let ambiguous = replayClass == .reconciled || replayClass == .nonReplayable
            _ = try? await repository.transitionToolInvocation(
                invocationID: record.invocationID,
                expected: .executing,
                to: ambiguous ? .ambiguous : .failed,
                lease: lease,
                errorCode: "tool_execution_failed",
                errorSummary: String(error.localizedDescription.prefix(2_048))
            )
            throw error
        }
    }

    private func complete(
        _ result: ToolResult,
        record: ToolInvocationRecord,
        expectedState: ToolInvocationState,
        lease: RunLease,
        context: ToolInvocationContext
    ) async throws -> ToolResult {
        let encoded = try Self.encodeResult(result)
        let limit = min(
            Self.maximumDurableResultBytes,
            context.authorizationScope.maximumInlineOutputBytes
        )
        guard encoded.utf8.count <= limit else {
            _ = try? await repository.transitionToolInvocation(
                invocationID: record.invocationID,
                expected: expectedState,
                to: .ambiguous,
                lease: lease,
                errorCode: AutonomyError.resultTooLarge.code,
                errorSummary: "Tool returned more bytes than the durable inline result limit"
            )
            throw AutonomyError.resultTooLarge
        }
        _ = try await repository.transitionToolInvocation(
            invocationID: record.invocationID,
            expected: expectedState,
            to: .completed,
            lease: lease,
            resultSHA256: JSONSupport.sha256Hex(encoded),
            resultSummary: encoded
        )
        return result
    }

    private static func encodeResult(_ result: ToolResult) throws -> String {
        try JSONSupport.canonicalJSON([
            "ok": result.ok,
            "is_error": result.isError,
            "payload": result.payload,
        ])
    }

    private static func decodeResult(_ value: String?) throws -> ToolResult {
        guard let value,
              let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              let ok = object["ok"] as? Bool,
              let isError = object["is_error"] as? Bool,
              let payload = object["payload"] as? [String: Any] else {
            throw ProjectContextError.integrityFailure("completed tool invocation has no valid durable result")
        }
        return ToolResult(ok: ok, payload: payload, isError: isError)
    }

    private static func durableCall(_ call: BrokeredToolCall) -> BrokeredToolCall {
        guard ProductionToolReplayCatalog.acceptsDurableIdempotencyArgument.contains(
            call.toolName
        ), call.arguments["idempotency_key"] == nil,
              let idempotencyKey = call.idempotencyKey,
              !idempotencyKey.isEmpty else {
            return call
        }
        var arguments = call.arguments
        arguments["idempotency_key"] = idempotencyKey
        return BrokeredToolCall(
            providerCallID: call.providerCallID,
            toolName: call.toolName,
            arguments: arguments,
            idempotencyKey: call.idempotencyKey
        )
    }
}

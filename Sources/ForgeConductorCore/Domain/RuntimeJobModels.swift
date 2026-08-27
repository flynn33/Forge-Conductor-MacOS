// RuntimeJobModels.swift
// Durable, project-bound execution-job contracts and bounded output metadata.

import Foundation

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case process
    case shell
    case bash
    case python
    case powershell
}

public enum RuntimeExecutionProfile: String, Codable, Sendable, CaseIterable {
    case directProcess = "direct_process"
    case zshNoProfile = "zsh_no_profile"
    case bashNoProfile = "bash_no_profile"
    case legacyBashLogin = "legacy_bash_login"
    case pythonIsolated = "python_isolated"
    case powershellNoProfile = "powershell_no_profile"
}

public enum RuntimeReplayClass: String, Codable, Sendable, CaseIterable {
    case readOnly = "read_only"
    case idempotent
    case reconciled
    case nonReplayable = "non_replayable"
}

public enum RuntimeJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case cancelling
    case completed
    case failed
    case timedOut = "timed_out"
    case cancelled
    case quarantinedStale = "quarantined_stale"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .timedOut, .cancelled, .quarantinedStale:
            true
        case .queued, .running, .cancelling:
            false
        }
    }
}

public enum RuntimeOutputStream: String, Codable, Sendable, CaseIterable {
    case stdout
    case stderr
}

enum RuntimeTerminationPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case termPending = "term_pending"
    case termSent = "term_sent"
    case killPending = "kill_pending"
    case killSent = "kill_sent"
    case confirmed
    case unconfirmed
}

struct RuntimeTerminationRecord: Sendable, Equatable {
    let jobID: UUID
    let identity: RuntimePersistedProcessIdentity
    let phase: RuntimeTerminationPhase
    let probeDeadline: String?
    let errorSummary: String?
}

public struct RuntimeJobShutdownReport: Sendable, Equatable {
    public let completed: Bool
    public let unresolvedJobIDs: [UUID]
    public let persistencePendingJobIDs: [UUID]

    public init(
        completed: Bool,
        unresolvedJobIDs: [UUID],
        persistencePendingJobIDs: [UUID]
    ) {
        self.completed = completed
        self.unresolvedJobIDs = unresolvedJobIDs
        self.persistencePendingJobIDs = persistencePendingJobIDs
    }
}

public struct RuntimeJobRequest: Sendable {
    public let kind: RuntimeKind
    public let profile: RuntimeExecutionProfile
    public let context: ToolInvocationContext
    public let executable: URL?
    public let arguments: [String]
    public let script: String?
    public let canonicalWorkingDirectory: URL
    public let timeout: Duration
    public let maximumInlineOutputBytes: Int
    public let replayClass: RuntimeReplayClass
    public let idempotencyKey: String?

    public init(
        kind: RuntimeKind,
        profile: RuntimeExecutionProfile,
        context: ToolInvocationContext,
        executable: URL? = nil,
        arguments: [String] = [],
        script: String? = nil,
        canonicalWorkingDirectory: URL,
        timeout: Duration,
        maximumInlineOutputBytes: Int = 64 * 1_024,
        replayClass: RuntimeReplayClass,
        idempotencyKey: String? = nil
    ) {
        self.kind = kind
        self.profile = profile
        self.context = context
        self.executable = executable
        self.arguments = arguments
        self.script = script
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
        self.timeout = timeout
        self.maximumInlineOutputBytes = maximumInlineOutputBytes
        self.replayClass = replayClass
        self.idempotencyKey = idempotencyKey
    }
}

public struct RuntimeJobRecord: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let runID: RunID?
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let runtimeKind: RuntimeKind
    public let executionProfile: RuntimeExecutionProfile
    public let replayClass: RuntimeReplayClass
    public let idempotencyKey: String?
    public let state: RuntimeJobState
    public let canonicalWorkingDirectory: URL
    public let commandSummary: String
    public let timeoutSeconds: Int
    public let exitCode: Int32?
    public let outputArtifactID: String?
    public let outputBytes: UInt64
    public let processIdentifier: Int32?
    public let processGroupIdentifier: Int32?
    public let errorCode: String?
    public let errorSummary: String?
    public let createdAt: String
    public let startedAt: String?
    public let completedAt: String?
    public let updatedAt: String
}

public struct RuntimeJobOutputMetadata: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let stream: RuntimeOutputStream
    public let inlineText: String
    public let artifactRelativePath: String?
    public let artifactDeviceIdentifier: UInt64?
    public let artifactFileIdentifier: UInt64?
    public let byteCount: UInt64
    public let retainedByteCount: UInt64
    public let sha256: String
    public let inlineTruncated: Bool
    public let artifactTruncated: Bool
    public let artifactEvicted: Bool
}

public struct RuntimeOutputSlice: Sendable, Equatable {
    public let jobID: UUID
    public let stream: RuntimeOutputStream
    public let offset: UInt64
    public let data: Data
    public let nextOffset: UInt64
    public let totalRetainedBytes: UInt64
    public let totalObservedBytes: UInt64
    public let eof: Bool
    public let artifactTruncated: Bool
    public let sha256: String
}

public struct RuntimeExecutableCapability: Codable, Sendable, Equatable {
    public let available: Bool
    public let executablePath: String?
    public let required: Bool
}

public struct RuntimeCapabilities: Codable, Sendable, Equatable {
    public let directProcess: RuntimeExecutableCapability
    public let zsh: RuntimeExecutableCapability
    public let bash: RuntimeExecutableCapability
    public let python: RuntimeExecutableCapability
    public let powershell: RuntimeExecutableCapability
    public let maximumConcurrentJobs: Int
    public let maximumCPUHeavyJobs: Int
    public let maximumInlineOutputBytes: Int
    public let maximumArtifactBytesPerJob: Int
    public let maximumArtifactBytesPerProject: Int
    public let maximumArtifactBytesGlobal: Int
    public let maximumRetainedArtifactJobsPerProject: Int

    public var shellAvailable: Bool { zsh.available && bash.available }
}

public struct RuntimeJobLimits: Sendable, Equatable {
    public let maximumConcurrentJobs: Int
    public let maximumCPUHeavyJobs: Int
    public let maximumQueuedJobs: Int
    public let maximumInlineOutputBytes: Int
    public let maximumArtifactBytesPerJob: Int
    public let maximumArtifactBytesPerProject: Int
    public let maximumArtifactBytesGlobal: Int
    public let maximumRetainedArtifactJobsPerProject: Int
    public let maximumScriptBytes: Int
    public let maximumArguments: Int
    public let maximumArgumentBytes: Int
    public let maximumTimeoutSeconds: Int
    public let terminationGraceMilliseconds: Int
    public let forcedTerminationGraceMilliseconds: Int
    public let maximumDescendantProcessesPerJob: Int
    public let maximumCPUSecondsPerProcess: Int
    public let maximumOpenFilesPerProcess: Int
    public let maximumFileBytesPerProcess: Int
    public let maximumCoreBytesPerProcess: Int

    public init(
        maximumConcurrentJobs: Int,
        maximumCPUHeavyJobs: Int,
        maximumQueuedJobs: Int = 64,
        maximumInlineOutputBytes: Int = 64 * 1_024,
        maximumArtifactBytesPerJob: Int,
        maximumArtifactBytesPerProject: Int = 256 * 1_048_576,
        maximumArtifactBytesGlobal: Int = 1_024 * 1_048_576,
        maximumRetainedArtifactJobsPerProject: Int = 256,
        maximumScriptBytes: Int = 1 * 1_024 * 1_024,
        maximumArguments: Int = 256,
        maximumArgumentBytes: Int = 64 * 1_024,
        maximumTimeoutSeconds: Int = 24 * 60 * 60,
        terminationGraceMilliseconds: Int = 500,
        forcedTerminationGraceMilliseconds: Int = 1_000,
        maximumDescendantProcessesPerJob: Int = 16,
        maximumCPUSecondsPerProcess: Int = 4 * 60 * 60,
        maximumOpenFilesPerProcess: Int = 256,
        maximumFileBytesPerProcess: Int = 1_024 * 1_024 * 1_024,
        maximumCoreBytesPerProcess: Int = 0
    ) {
        self.maximumConcurrentJobs = maximumConcurrentJobs
        self.maximumCPUHeavyJobs = maximumCPUHeavyJobs
        self.maximumQueuedJobs = maximumQueuedJobs
        self.maximumInlineOutputBytes = maximumInlineOutputBytes
        self.maximumArtifactBytesPerJob = maximumArtifactBytesPerJob
        self.maximumArtifactBytesPerProject = maximumArtifactBytesPerProject
        self.maximumArtifactBytesGlobal = maximumArtifactBytesGlobal
        self.maximumRetainedArtifactJobsPerProject = maximumRetainedArtifactJobsPerProject
        self.maximumScriptBytes = maximumScriptBytes
        self.maximumArguments = maximumArguments
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumTimeoutSeconds = maximumTimeoutSeconds
        self.terminationGraceMilliseconds = terminationGraceMilliseconds
        self.forcedTerminationGraceMilliseconds = forcedTerminationGraceMilliseconds
        self.maximumDescendantProcessesPerJob = maximumDescendantProcessesPerJob
        self.maximumCPUSecondsPerProcess = maximumCPUSecondsPerProcess
        self.maximumOpenFilesPerProcess = maximumOpenFilesPerProcess
        self.maximumFileBytesPerProcess = maximumFileBytesPerProcess
        self.maximumCoreBytesPerProcess = maximumCoreBytesPerProcess
    }

    public static var current: RuntimeJobLimits {
        let memory = ProcessInfo.processInfo.physicalMemory
        let concurrent: Int
        let cpuHeavy: Int
        if memory <= 8 * ResourcePolicy.gibibyte {
            concurrent = 2
            cpuHeavy = 1
        } else if memory <= 16 * ResourcePolicy.gibibyte {
            concurrent = 2
            cpuHeavy = 1
        } else if memory <= 32 * ResourcePolicy.gibibyte {
            concurrent = 4
            cpuHeavy = 2
        } else {
            concurrent = 6
            cpuHeavy = 3
        }
        return RuntimeJobLimits(
            maximumConcurrentJobs: concurrent,
            maximumCPUHeavyJobs: cpuHeavy,
            maximumArtifactBytesPerJob: ResourcePolicy.current.nominalLimits.processOutputBytesPerStream * 2,
            maximumArtifactBytesPerProject:
                ResourcePolicy.current.nominalLimits.processOutputBytesPerStream * 16,
            maximumArtifactBytesGlobal:
                ResourcePolicy.current.nominalLimits.processOutputBytesPerStream * 64
        )
    }
}

public enum RuntimeJobError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unauthorizedTool(String)
    case workingDirectoryOutsideProject(String)
    case executableUnavailable(String)
    case queueFull
    case jobNotFound(UUID)
    case jobScopeMismatch(UUID)
    case invalidTransition(from: RuntimeJobState, to: RuntimeJobState)
    case outputUnavailable(UUID, RuntimeOutputStream)
    case artifactEvicted(UUID, RuntimeOutputStream)
    case artifactQuotaExhausted(ProjectID)
    case spawnFailed(Int32)
    case terminationUnconfirmed(Int32)
    case storageFailure(String)
    case repositoryClosed

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .unauthorizedTool: "tool_not_authorized"
        case .workingDirectoryOutsideProject: "cwd_outside_authorized_roots"
        case .executableUnavailable: "runtime_unavailable"
        case .queueFull: "runtime_queue_full"
        case .jobNotFound: "runtime_job_not_found"
        case .jobScopeMismatch: "runtime_job_scope_mismatch"
        case .invalidTransition: "runtime_job_invalid_transition"
        case .outputUnavailable: "runtime_output_unavailable"
        case .artifactEvicted: "runtime_artifact_evicted"
        case .artifactQuotaExhausted: "runtime_artifact_quota_exhausted"
        case .spawnFailed: "runtime_spawn_failed"
        case .terminationUnconfirmed: "runtime_termination_unconfirmed"
        case .storageFailure: "runtime_storage_failure"
        case .repositoryClosed: "runtime_repository_closed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): reason
        case .unauthorizedTool(let tool): "Tool is not authorized by this project context: \(tool)"
        case .workingDirectoryOutsideProject(let path): "Working directory is outside authorized project roots: \(path)"
        case .executableUnavailable(let name): "Runtime executable is unavailable: \(name)"
        case .queueFull: "The bounded runtime job queue is full"
        case .jobNotFound(let jobID): "Runtime job was not found: \(jobID.uuidString.lowercased())"
        case .jobScopeMismatch(let jobID): "Runtime job does not belong to this project generation: \(jobID.uuidString.lowercased())"
        case .invalidTransition(let from, let to): "Invalid runtime job transition: \(from.rawValue) to \(to.rawValue)"
        case .outputUnavailable(let jobID, let stream): "No \(stream.rawValue) output exists for job \(jobID.uuidString.lowercased())"
        case .artifactEvicted(let jobID, let stream): "The retained \(stream.rawValue) artifact was evicted for job \(jobID.uuidString.lowercased())"
        case .artifactQuotaExhausted(let projectID): "Runtime artifact quota is exhausted for project \(projectID.description)"
        case .spawnFailed(let code): "Process spawn failed with errno \(code)"
        case .terminationUnconfirmed(let processGroup): "Process group \(processGroup) did not confirm termination"
        case .storageFailure(let reason): "Runtime job storage failed: \(reason)"
        case .repositoryClosed: "Runtime job repository is closed"
        }
    }
}

public protocol ExecutionJobServicing: Sendable {
    func submit(_ request: RuntimeJobRequest) async throws -> UUID
    func status(jobID: UUID, context: ToolInvocationContext) async throws -> RuntimeJobRecord
    func readOutput(
        jobID: UUID,
        stream: RuntimeOutputStream,
        offset: UInt64,
        limit: Int,
        context: ToolInvocationContext
    ) async throws -> RuntimeOutputSlice
    func cancel(jobID: UUID, context: ToolInvocationContext) async throws
}

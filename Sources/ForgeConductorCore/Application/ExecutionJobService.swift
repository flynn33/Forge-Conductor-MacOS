// ExecutionJobService.swift
// Bounded asynchronous runtime jobs with exact project-generation commit fencing.

import CryptoKit
import Darwin
import Foundation

public protocol RuntimeJobContextValidating: Sendable {
    func validateCaller(_ context: ToolInvocationContext) async throws
    func prepareJob(jobID: UUID, context: ToolInvocationContext) async throws -> ToolInvocationContext
    func contextForStoredJob(jobID: UUID) async throws -> ToolInvocationContext
    func validateJob(jobID: UUID, context: ToolInvocationContext) async throws
    func commitJobResult(jobID: UUID, context: ToolInvocationContext, resultSHA256: String) async throws
}

public extension RuntimeJobContextValidating {
    func contextForStoredJob(jobID: UUID) async throws -> ToolInvocationContext {
        throw RuntimeJobError.storageFailure(
            "the configured runtime context validator cannot resolve stored job authority"
        )
    }
}

public protocol RuntimeJobLaunchObserving: Sendable {
    func processDidSpawn(jobID: UUID, processIdentifier: Int32) async
}

public struct NoopRuntimeJobLaunchObserver: RuntimeJobLaunchObserving, Sendable {
    public init() {}

    public func processDidSpawn(jobID: UUID, processIdentifier: Int32) async {}
}

public protocol RuntimeJobTerminalPersistenceHook: Sendable {
    func beforeTerminalPersistence(jobID: UUID) async throws
}

public struct NoopRuntimeJobTerminalPersistenceHook: RuntimeJobTerminalPersistenceHook, Sendable {
    public init() {}

    public func beforeTerminalPersistence(jobID: UUID) async throws {}
}

public struct ProjectControlPlaneRuntimeJobContextValidator: RuntimeJobContextValidating, Sendable {
    private let repository: ProjectControlPlaneRepository

    public init(repository: ProjectControlPlaneRepository) {
        self.repository = repository
    }

    public func validateCaller(_ context: ToolInvocationContext) async throws {
        try await repository.validate(context, for: Self.owner(for: context))
    }

    public func prepareJob(jobID: UUID, context: ToolInvocationContext) async throws -> ToolInvocationContext {
        try await validateCaller(context)
        let jobOwner = ProjectBindingOwner(
            kind: .runtimeJob,
            id: jobID.uuidString.lowercased()
        )
        _ = try await repository.bind(
            owner: jobOwner,
            projectID: context.projectID,
            generation: context.projectGeneration,
            runID: context.runID,
            authorizationScope: context.authorizationScope
        )
        return ToolInvocationContext(
            projectID: context.projectID,
            projectGeneration: context.projectGeneration,
            clientID: context.clientID,
            runID: context.runID,
            providerSessionID: context.providerSessionID,
            runtimeJobID: jobID,
            authorizationScope: context.authorizationScope
        )
    }

    public func contextForStoredJob(jobID: UUID) async throws -> ToolInvocationContext {
        try await repository.invocationContext(
            for: ProjectBindingOwner(
                kind: .runtimeJob,
                id: jobID.uuidString.lowercased()
            ),
            clientID: ClientID("manager-runtime-job")
        )
    }

    public func validateJob(jobID: UUID, context: ToolInvocationContext) async throws {
        guard context.runtimeJobID == jobID else {
            throw RuntimeJobError.jobScopeMismatch(jobID)
        }
        try await repository.validate(
            context,
            for: ProjectBindingOwner(kind: .runtimeJob, id: jobID.uuidString.lowercased())
        )
    }

    public func commitJobResult(
        jobID: UUID,
        context: ToolInvocationContext,
        resultSHA256: String
    ) async throws {
        guard context.runtimeJobID == jobID else {
            throw RuntimeJobError.jobScopeMismatch(jobID)
        }
        _ = resultSHA256
        try await repository.validate(
            context,
            for: ProjectBindingOwner(kind: .runtimeJob, id: jobID.uuidString.lowercased())
        )
    }

    private static func owner(for context: ToolInvocationContext) -> ProjectBindingOwner {
        if let jobID = context.runtimeJobID {
            return ProjectBindingOwner(kind: .runtimeJob, id: jobID.uuidString.lowercased())
        }
        if let providerSessionID = context.providerSessionID {
            return ProjectBindingOwner(kind: .providerSession, id: providerSessionID)
        }
        if let runID = context.runID {
            return ProjectBindingOwner(kind: .autonomousRun, id: runID.description)
        }
        return ProjectBindingOwner(kind: .mcpClient, id: context.clientID.rawValue)
    }
}

public struct RuntimeCapabilityDiscoverer: Sendable {
    private static let probeTimeoutSeconds: TimeInterval = 2
    private static let probeMaximumOutputBytes = 1_024
    private static let pythonProbePrefix = "forge-runtime-python:"
    private static let powershellProbePrefix = "forge-runtime-powershell:Core:"

    private let configuredPython: URL?
    private let configuredPowerShell: URL?

    public init(configuredPython: URL? = nil, configuredPowerShell: URL? = nil) {
        self.configuredPython = configuredPython
        self.configuredPowerShell = configuredPowerShell
    }

    public func discover(limits: RuntimeJobLimits = .current) -> RuntimeCapabilities {
        let isolationAvailable = RuntimeProcessSandbox.isAvailable
            && RuntimeLaunchGate.isAvailable
        let zsh = Self.capability(
            path: "/bin/zsh",
            required: true,
            isolationAvailable: isolationAvailable
        )
        let bash = Self.capability(
            path: "/bin/bash",
            required: true,
            isolationAvailable: isolationAvailable
        )
        let python = Self.pythonCapability(
            configured: configuredPython,
            isolationAvailable: isolationAvailable
        )
        let powershell = Self.powershellCapability(
            configured: configuredPowerShell,
            isolationAvailable: isolationAvailable
        )
        return RuntimeCapabilities(
            directProcess: RuntimeExecutableCapability(
                available: isolationAvailable,
                executablePath: isolationAvailable ? RuntimeProcessSandbox.executable.path : nil,
                required: true
            ),
            zsh: zsh,
            bash: bash,
            python: python,
            powershell: powershell,
            maximumConcurrentJobs: limits.maximumConcurrentJobs,
            maximumCPUHeavyJobs: limits.maximumCPUHeavyJobs,
            maximumInlineOutputBytes: limits.maximumInlineOutputBytes,
            maximumArtifactBytesPerJob: limits.maximumArtifactBytesPerJob,
            maximumArtifactBytesPerProject: limits.maximumArtifactBytesPerProject,
            maximumArtifactBytesGlobal: limits.maximumArtifactBytesGlobal,
            maximumRetainedArtifactJobsPerProject:
                limits.maximumRetainedArtifactJobsPerProject
        )
    }

    private static func pythonCapability(
        configured: URL?,
        isolationAvailable: Bool
    ) -> RuntimeExecutableCapability {
        if let configured {
            if configured.standardizedFileURL.path == "/usr/bin/python3" {
                return pythonCapability(configured: nil, isolationAvailable: isolationAvailable)
            }
            guard RuntimeProcessSandbox.isImmutableSystemRuntime(configured) else {
                return RuntimeExecutableCapability(
                    available: false,
                    executablePath: nil,
                    required: false
                )
            }
            return verifiedPythonCapability(
                configured,
                isolationAvailable: isolationAvailable
            )
        }
        let xcodePython = URL(
            fileURLWithPath:
                "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/Current/Resources/Python.app/Contents/MacOS/Python"
        )
        if FileManager.default.isExecutableFile(atPath: xcodePython.path) {
            return verifiedPythonCapability(
                xcodePython,
                isolationAvailable: isolationAvailable
            )
        }
        guard let discovered = ProcessRunner.which("python3"),
              discovered != "/usr/bin/python3" else {
            return RuntimeExecutableCapability(available: false, executablePath: nil, required: false)
        }
        let discoveredURL = URL(fileURLWithPath: discovered)
        guard RuntimeProcessSandbox.isImmutableSystemRuntime(discoveredURL) else {
            return RuntimeExecutableCapability(available: false, executablePath: nil, required: false)
        }
        return verifiedPythonCapability(
            discoveredURL,
            isolationAvailable: isolationAvailable
        )
    }

    private static func powershellCapability(
        configured: URL?,
        isolationAvailable: Bool
    ) -> RuntimeExecutableCapability {
        let candidate: URL?
        if let configured {
            candidate = configured
        } else if let discovered = ProcessRunner.which("pwsh") {
            candidate = URL(fileURLWithPath: discovered)
        } else {
            candidate = nil
        }
        guard let candidate,
              RuntimeProcessSandbox.isImmutableSystemRuntime(candidate) else {
            return RuntimeExecutableCapability(available: false, executablePath: nil, required: false)
        }
        return verifiedPowerShellCapability(
            candidate,
            isolationAvailable: isolationAvailable
        )
    }

    private static func verifiedPythonCapability(
        _ candidate: URL,
        isolationAvailable: Bool
    ) -> RuntimeExecutableCapability {
        verifiedOptionalCapability(
            candidate,
            isolationAvailable: isolationAvailable,
            probe: probePython
        )
    }

    private static func verifiedPowerShellCapability(
        _ candidate: URL,
        isolationAvailable: Bool
    ) -> RuntimeExecutableCapability {
        verifiedOptionalCapability(
            candidate,
            isolationAvailable: isolationAvailable,
            probe: probePowerShell
        )
    }

    private static func verifiedOptionalCapability(
        _ candidate: URL,
        isolationAvailable: Bool,
        probe: (URL) -> Bool
    ) -> RuntimeExecutableCapability {
        guard isolationAvailable else { return unavailableOptionalCapability() }
        let canonical = RuntimeProcessSandbox.canonicalExistingURL(candidate)
        guard RuntimeProcessSandbox.isImmutableSystemRuntime(canonical),
              FileManager.default.isExecutableFile(atPath: canonical.path),
              probe(canonical) else {
            return unavailableOptionalCapability()
        }
        return RuntimeExecutableCapability(
            available: true,
            executablePath: canonical.path,
            required: false
        )
    }

    private static func probePython(_ executable: URL) -> Bool {
        let script = "import sys;sys.stdout.write('\(pythonProbePrefix)%d.%d.%d' % sys.version_info[:3])"
        guard let result = boundedProbe(
            executable,
            arguments: ["-I", "-B", "-c", script]
        ),
        result.stdout.hasPrefix(pythonProbePrefix) else {
            return false
        }
        let version = String(result.stdout.dropFirst(pythonProbePrefix.count))
        return validSemanticVersion(version, requiredMajor: 3)
    }

    private static func probePowerShell(_ executable: URL) -> Bool {
        let command = """
        $ErrorActionPreference='Stop';$version=$PSVersionTable.PSVersion;$edition=$PSVersionTable.PSEdition;if($null -eq $version -or $edition -ne 'Core' -or $version.Major -lt 7){exit 64};[Console]::Out.Write(('\(powershellProbePrefix){0}.{1}.{2}' -f $version.Major,$version.Minor,$version.Patch))
        """
        guard let result = boundedProbe(
            executable,
            arguments: ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]
        ),
        result.stdout.hasPrefix(powershellProbePrefix) else {
            return false
        }
        let version = String(result.stdout.dropFirst(powershellProbePrefix.count))
        return validSemanticVersion(version, minimumMajor: 7)
    }

    private static func boundedProbe(
        _ executable: URL,
        arguments: [String]
    ) -> ProcessResult? {
        do {
            let result = try ProcessRunner().run(
                executable: executable.path,
                arguments: arguments,
                environment: [
                    "NO_COLOR": "1",
                    "TERM": "dumb",
                ],
                timeoutSec: probeTimeoutSeconds,
                maximumOutputBytes: probeMaximumOutputBytes
            )
            guard result.exitCode == 0,
                  !result.timedOut,
                  !result.stdoutTruncated,
                  !result.stderrTruncated else {
                return nil
            }
            return result
        } catch {
            return nil
        }
    }

    private static func validSemanticVersion(
        _ value: String,
        requiredMajor: Int? = nil,
        minimumMajor: Int? = nil
    ) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ component in
                  !component.isEmpty && component.allSatisfy(\.isNumber)
              }),
              let major = Int(components[0]),
              Int(components[1]) != nil,
              Int(components[2]) != nil else {
            return false
        }
        if let requiredMajor, major != requiredMajor { return false }
        if let minimumMajor, major < minimumMajor { return false }
        return true
    }

    private static func unavailableOptionalCapability() -> RuntimeExecutableCapability {
        RuntimeExecutableCapability(available: false, executablePath: nil, required: false)
    }

    private static func capability(
        path: String,
        required: Bool,
        isolationAvailable: Bool
    ) -> RuntimeExecutableCapability {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let available = isolationAvailable
            && FileManager.default.isExecutableFile(atPath: canonical.path)
        return RuntimeExecutableCapability(
            available: available,
            executablePath: available ? canonical.path : nil,
            required: required
        )
    }
}

public actor ExecutionJobService: ExecutionJobServicing {
    private struct JobDirectoryCandidate: Sendable {
        let url: URL
        let root: URL
        let projectID: ProjectID
        let generation: ProjectGeneration
        let jobID: UUID
    }

    private static let maximumStartupOrphanDirectories = 256
    private static let maximumStartupDirectoryEntries = 2_048

    private struct PendingExecution: Sendable {
        let request: RuntimeJobRequest
        let jobContext: ToolInvocationContext
        let plan: RuntimeProcessPlan
        let spool: RuntimeOutputSpool
        let requestArtifactRelativePath: String?
        let cpuHeavy: Bool
    }

    private struct ActiveExecution {
        let task: Task<Void, Never>
        let cpuHeavy: Bool
        let jobContext: ToolInvocationContext
        let item: PendingExecution
        var process: RuntimeActiveProcess?
        var cancellationRequested: Bool
        var terminalPersistenceFailure: String?
        var pendingTerminationCompletion: PendingTerminationCompletion?
    }

    private struct PendingTerminationCompletion: Sendable {
        let item: PendingExecution
        let terminalState: RuntimeJobState
        let exitCode: Int32?
        let errorCode: String
        let errorSummary: String
    }

    private struct ArtifactReservation: Sendable {
        let projectID: ProjectID
        let requestBytes: UInt64
        let outputBytes: UInt64

        var totalBytes: UInt64 {
            Self.saturatingAdd(requestBytes, outputBytes)
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    private struct TerminalPersistencePayload: Sendable {
        let jobID: UUID
        let state: RuntimeJobState
        let exitCode: Int32?
        let outputs: [RuntimeJobOutputMetadata]
        let artifactID: String?
        let errorCode: String?
        let errorSummary: String?
        let expectedContext: ToolInvocationContext?
    }

    public let repository: RuntimeJobRepository
    public let artifactRoot: URL
    public let limits: RuntimeJobLimits

    private let contextValidator: any RuntimeJobContextValidating
    private let launchObserver: any RuntimeJobLaunchObserving
    private let terminalPersistenceHook: any RuntimeJobTerminalPersistenceHook
    private let discoveredCapabilities: RuntimeCapabilities
    private let processEnvironment: [String: String]
    private let launcherURL: URL
    private var recoveredProcessController: any RuntimeRecoveredProcessControlling =
        DarwinRuntimeRecoveredProcessController()
    private var pending: [UUID: PendingExecution] = [:]
    private var pendingOrder: [UUID] = []
    private var active: [UUID: ActiveExecution] = [:]
    private var artifactReservations: [UUID: ArtifactReservation] = [:]
    private var persistenceRecoveryJobs: Set<UUID> = []
    private var persistenceRecoveryPayloads: [UUID: TerminalPersistencePayload] = [:]
    private var persistenceRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var terminationRecoveryJobs: Set<UUID> = []
    private var terminationRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var shuttingDown = false

    public init(
        repository: RuntimeJobRepository,
        contextValidator: any RuntimeJobContextValidating,
        artifactRoot: URL,
        limits: RuntimeJobLimits = .current,
        capabilityDiscoverer: RuntimeCapabilityDiscoverer = RuntimeCapabilityDiscoverer(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchObserver: any RuntimeJobLaunchObserving = NoopRuntimeJobLaunchObserver(),
        terminalPersistenceHook: any RuntimeJobTerminalPersistenceHook =
            NoopRuntimeJobTerminalPersistenceHook()
    ) throws {
        guard limits.maximumConcurrentJobs > 0,
              limits.maximumCPUHeavyJobs > 0,
              limits.maximumCPUHeavyJobs <= limits.maximumConcurrentJobs,
              limits.maximumQueuedJobs > 0,
              limits.maximumInlineOutputBytes > 0,
              limits.maximumArtifactBytesPerJob >= limits.maximumInlineOutputBytes,
              limits.maximumArtifactBytesPerProject >= limits.maximumArtifactBytesPerJob,
              limits.maximumArtifactBytesGlobal >= limits.maximumArtifactBytesPerProject,
              limits.maximumRetainedArtifactJobsPerProject > 0,
              limits.maximumScriptBytes > 0,
              limits.maximumArguments > 0,
              limits.maximumArgumentBytes > 0,
              limits.maximumTimeoutSeconds > 0,
              (0...10_000).contains(limits.terminationGraceMilliseconds),
              (1...10_000).contains(limits.forcedTerminationGraceMilliseconds),
              (1...1_024).contains(limits.maximumDescendantProcessesPerJob),
              (1...24 * 60 * 60).contains(limits.maximumCPUSecondsPerProcess),
              (16...4_096).contains(limits.maximumOpenFilesPerProcess),
              (1...(16 * 1_024 * 1_024 * 1_024)).contains(limits.maximumFileBytesPerProcess),
              (0...(1_024 * 1_024 * 1_024)).contains(limits.maximumCoreBytesPerProcess) else {
            throw RuntimeJobError.invalidRequest("runtime job limits are internally inconsistent")
        }
        let standardizedArtifactRoot = artifactRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedArtifactRoot,
            withIntermediateDirectories: true
        )
        let canonicalArtifactRoot = RuntimeProcessSandbox.canonicalExistingURL(
            standardizedArtifactRoot
        )
        _ = chmod(canonicalArtifactRoot.path, S_IRWXU)
        let installedLauncher = try RuntimeLaunchGate.install(
            serviceRoot: canonicalArtifactRoot
        )
        self.repository = repository
        self.contextValidator = contextValidator
        self.launchObserver = launchObserver
        self.terminalPersistenceHook = terminalPersistenceHook
        self.artifactRoot = canonicalArtifactRoot
        self.limits = limits
        launcherURL = installedLauncher
        discoveredCapabilities = capabilityDiscoverer.discover(limits: limits)
        processEnvironment = Self.sanitizedEnvironment(environment)
    }

    public func start() async throws {
        guard !started else { return }
        try await sweepOrphanedJobDirectories()
        let interrupted = try await repository.nonterminalJobs()
        for job in interrupted {
            var recoverySummary =
                "Execution owner restarted before a terminal job result was committed"
            if let identity = try await repository.recoveryProcessIdentity(jobID: job.jobID) {
                recoverySummary += try await terminateRecoveredProcessGroup(
                    jobID: job.jobID,
                    identity: identity
                )
            } else if job.state == .queued {
                recoverySummary +=
                    "; queued intent had no committed process owner, so its gated launcher could not execute the target"
            } else {
                // The launch gate prevents target execution until the exact identity is
                // committed. A running record without that identity is still corrupt
                // durable state and must fail closed rather than be guessed dead.
                throw RuntimeJobError.storageFailure(
                    "runtime recovery is blocked because job \(job.jobID.uuidString.lowercased()) has no exact process-start identity"
                )
            }
            try deleteInterruptedArtifacts(job)
            try await repository.markInterrupted(
                jobID: job.jobID,
                summary: recoverySummary
            )
        }
        await compactArtifacts(projectID: nil)
        await compactTerminalLedger()
        started = true
    }

    private func terminateRecoveredProcessGroup(
        jobID: UUID,
        identity: RuntimePersistedProcessIdentity
    ) async throws -> String {
        let result = try await reapPersistedProcessGroup(jobID: jobID, identity: identity)
        return Self.recoverySignalSummary(
            termination: result.termination,
            forced: result.forced
        )
    }

    private func reapPersistedProcessGroup(
        jobID: UUID,
        identity: RuntimePersistedProcessIdentity
    ) async throws -> (
        termination: RuntimeRecoveredProcessSignalResult,
        forced: RuntimeRecoveredProcessSignalResult?
    ) {
        let totalMilliseconds = limits.terminationGraceMilliseconds
            + limits.forcedTerminationGraceMilliseconds
            + 500
        let persistedDeadline = ISO8601.string(
            from: Date().addingTimeInterval(Double(totalMilliseconds) / 1_000)
        )
        var durable = try await repository.beginOrResumeTermination(
            jobID: jobID,
            identity: identity,
            probeDeadline: persistedDeadline
        )
        if durable.phase == .confirmed {
            return (.processMissing, nil)
        }

        let clock = ContinuousClock()
        let terminationDeadline = clock.now
            + .milliseconds(max(0, limits.terminationGraceMilliseconds))
        var termination: RuntimeRecoveredProcessSignalResult = .signaled
        if durable.phase == .termPending {
            termination = await signalRecoveredProcessGroup(
                SIGTERM,
                identity: identity,
                before: terminationDeadline
            )
            if termination == .processMissing {
                try await repository.recordTerminationPhase(jobID: jobID, phase: .confirmed)
                return (termination, nil)
            }
            guard termination == .signaled else {
                try await persistUnconfirmedTermination(
                    jobID: jobID,
                    identity: identity,
                    reason: "SIGTERM could not be delivered: \(Self.signalDescription(termination))"
                )
            }
            try await repository.recordTerminationPhase(jobID: jobID, phase: .termSent)
            durable = try await repository.terminationRecord(jobID: jobID) ?? durable
        }

        if durable.phase == .termSent,
           await recoveredProcessGroupIsGone(
            identity,
            before: terminationDeadline
           ) {
            try await repository.recordTerminationPhase(jobID: jobID, phase: .confirmed)
            return (termination, nil)
        }

        if durable.phase != .killSent {
            try await repository.recordTerminationPhase(jobID: jobID, phase: .killPending)
        }
        let forcedDeadline = clock.now
            + .milliseconds(max(0, limits.forcedTerminationGraceMilliseconds))
        let forced = await signalRecoveredProcessGroup(
            SIGKILL,
            identity: identity,
            before: forcedDeadline
        )
        if forced == .processMissing {
            try await repository.recordTerminationPhase(jobID: jobID, phase: .confirmed)
            return (termination, forced)
        }
        guard forced == .signaled else {
            try await persistUnconfirmedTermination(
                jobID: jobID,
                identity: identity,
                reason: "SIGKILL could not be delivered: \(Self.signalDescription(forced))"
            )
        }
        try await repository.recordTerminationPhase(jobID: jobID, phase: .killSent)
        guard await recoveredProcessGroupIsGone(
            identity,
            before: forcedDeadline
        ) else {
            try await persistUnconfirmedTermination(
                jobID: jobID,
                identity: identity,
                reason: "process group remained alive through the persisted probe deadline"
            )
        }
        try await repository.recordTerminationPhase(jobID: jobID, phase: .confirmed)
        return (termination, forced)
    }

    private func persistUnconfirmedTermination(
        jobID: UUID,
        identity: RuntimePersistedProcessIdentity,
        reason: String
    ) async throws -> Never {
        try await repository.recordTerminationPhase(
            jobID: jobID,
            phase: .unconfirmed,
            errorSummary: reason
        )
        throw RuntimeJobError.terminationUnconfirmed(identity.processGroupIdentifier)
    }

    private func terminateLaunchedProcess(
        jobID: UUID,
        process: RuntimeActiveProcess
    ) async throws {
        guard let identity = Self.persistedIdentity(for: process) else {
            throw RuntimeJobError.storageFailure(
                "runtime process does not have an exact process-start identity"
            )
        }
        if let durableIdentity = try await repository.recoveryProcessIdentity(jobID: jobID) {
            guard durableIdentity == identity else {
                throw RuntimeJobError.storageFailure(
                    "runtime process identity changed before termination"
                )
            }
            _ = try await reapPersistedProcessGroup(jobID: jobID, identity: identity)
            return
        }

        // Before markRunning commits, the target remains behind the launch gate.
        // Closing that gate and reaping the native launcher is safe without creating
        // a guessed durable identity for a queued job.
        process.abortBeforeExecution()
        _ = try await process.terminateAndWait(
            graceMilliseconds: limits.terminationGraceMilliseconds,
            forcedGraceMilliseconds: limits.forcedTerminationGraceMilliseconds
        )
    }

    private func signalRecoveredProcessGroup(
        _ signal: Int32,
        identity: RuntimePersistedProcessIdentity,
        before deadline: ContinuousClock.Instant
    ) async -> RuntimeRecoveredProcessSignalResult {
        let clock = ContinuousClock()
        repeat {
            let result = await recoveredProcessController.signalProcessGroup(
                signal,
                expectedIdentity: identity
            )
            guard result == .identityUnavailable, clock.now < deadline else {
                return result
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while true
    }

    private func recoveredProcessGroupIsGone(
        _ identity: RuntimePersistedProcessIdentity,
        before deadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        repeat {
            let probe = await recoveredProcessController.signalProcessGroup(
                0,
                expectedIdentity: identity
            )
            if probe == .processMissing { return true }
            if probe != .signaled, probe != .identityUnavailable { return false }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        } while true
    }

    func setRecoveredProcessController(
        _ controller: any RuntimeRecoveredProcessControlling
    ) throws {
        guard !started else {
            throw RuntimeJobError.invalidRequest(
                "recovered process controller must be installed before runtime startup"
            )
        }
        recoveredProcessController = controller
    }

    public func capabilities() -> RuntimeCapabilities { discoveredCapabilities }

    public func recoveryPendingJobIDs() -> [UUID] {
        let activeFailures = active.compactMap { jobID, execution in
            execution.terminalPersistenceFailure == nil ? nil : jobID
        }
        return Array(
            Set(activeFailures)
                .union(persistenceRecoveryJobs)
                .union(terminationRecoveryJobs)
        )
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func submit(_ request: RuntimeJobRequest) async throws -> UUID {
        try Task.checkCancellation()
        try await ensureStarted()
        guard !shuttingDown else {
            throw RuntimeJobError.invalidRequest("runtime job service is shutting down")
        }
        try await contextValidator.validateCaller(request.context)
        try Task.checkCancellation()
        let validated = try validate(request)
        if let key = request.idempotencyKey,
           let existing = try await repository.existingJob(
            projectID: request.context.projectID,
            generation: request.context.projectGeneration,
            idempotencyKey: key
           ) {
            return existing.jobID
        }
        guard pending.count + active.count < limits.maximumQueuedJobs + limits.maximumConcurrentJobs else {
            throw RuntimeJobError.queueFull
        }
        try Task.checkCancellation()

        let jobID = UUID()
        let outputArtifactBudget = try await reserveArtifactCapacity(
            jobID: jobID,
            request: request
        )
        let spool: RuntimeOutputSpool
        do {
            spool = try RuntimeOutputSpool(
                jobID: jobID,
                projectID: request.context.projectID,
                generation: request.context.projectGeneration,
                artifactRoot: artifactRoot,
                maximumInlineBytes: validated.inlineBytes,
                maximumArtifactBytes: outputArtifactBudget
            )
        } catch {
            releaseArtifactReservation(jobID: jobID)
            throw error
        }
        var preserveReservationForRecovery = false
        do {
            let planned = try buildPlan(
                jobID: jobID,
                request: request,
                canonicalWorkingDirectory: validated.workingDirectory,
                spool: spool
            )
            // This is the last cancellation boundary before the durable queued
            // job record commits. After createJob succeeds, recovery must finish
            // wiring or terminalizing that exact job even if the caller leaves.
            try Task.checkCancellation()
            let persistedRequest = RuntimeJobRequest(
                kind: request.kind,
                profile: request.profile,
                context: request.context,
                executable: request.executable,
                arguments: request.arguments,
                script: request.script,
                canonicalWorkingDirectory: validated.workingDirectory,
                timeout: request.timeout,
                maximumInlineOutputBytes: validated.inlineBytes,
                replayClass: request.replayClass,
                idempotencyKey: request.idempotencyKey
            )
            let persisted = try await repository.createJob(
                jobID: jobID,
                request: persistedRequest,
                commandSummary: planned.summary,
                timeoutSeconds: validated.timeoutSeconds,
                requestArtifactRelativePath: planned.requestArtifactRelativePath,
                commitObserver: request.didPersist
            )
            guard persisted.jobID == jobID else {
                spool.discard()
                releaseArtifactReservation(jobID: jobID)
                return persisted.jobID
            }
            let jobContext: ToolInvocationContext
            do {
                jobContext = try await contextValidator.prepareJob(
                    jobID: jobID,
                    context: request.context
                )
            } catch {
                spool.discard()
                let terminalPersisted = await persistTerminal(
                    jobID: jobID,
                    state: error is ProjectContextError ? .quarantinedStale : .failed,
                    exitCode: nil,
                    outputs: [],
                    artifactID: nil,
                    errorCode: (error as? ProjectContextError)?.code ?? "runtime_context_binding_failed",
                    errorSummary: error.localizedDescription,
                    expectedContext: request.context
                )
                preserveReservationForRecovery = !terminalPersisted
                throw error
            }
            pending[jobID] = PendingExecution(
                request: persistedRequest,
                jobContext: jobContext,
                plan: planned.plan,
                spool: spool,
                requestArtifactRelativePath: planned.requestArtifactRelativePath,
                cpuHeavy: Self.isCPUHeavy(request.kind)
            )
            pendingOrder.append(jobID)
            pumpQueue()
            return jobID
        } catch {
            spool.discard()
            if !preserveReservationForRecovery {
                releaseArtifactReservation(jobID: jobID)
            }
            throw error
        }
    }

    public func submitLegacyBashLogin(
        command: String,
        workingDirectory: URL,
        timeoutSeconds: Int,
        context: ToolInvocationContext,
        replayClass: RuntimeReplayClass,
        idempotencyKey: String? = nil
    ) async throws -> UUID {
        try await submitLegacyBashLoginObservingPersistence(
            command: command,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            context: context,
            replayClass: replayClass,
            idempotencyKey: idempotencyKey,
            didPersist: nil
        )
    }

    func submitLegacyBashLoginObservingPersistence(
        command: String,
        workingDirectory: URL,
        timeoutSeconds: Int,
        context: ToolInvocationContext,
        replayClass: RuntimeReplayClass,
        idempotencyKey: String? = nil,
        didPersist: (@Sendable (RuntimeJobRecord) -> Void)?
    ) async throws -> UUID {
        let request: RuntimeJobRequest
        if let didPersist {
            request = RuntimeJobRequest(
                kind: .bash,
                profile: .legacyBashLogin,
                context: context,
                script: command,
                canonicalWorkingDirectory: workingDirectory,
                timeout: .seconds(min(min(timeoutSeconds, 120), limits.maximumTimeoutSeconds)),
                maximumInlineOutputBytes: min(
                    context.authorizationScope.maximumInlineOutputBytes,
                    limits.maximumInlineOutputBytes
                ),
                replayClass: replayClass,
                idempotencyKey: idempotencyKey,
                persistenceObserver: didPersist
            )
        } else {
            request = RuntimeJobRequest(
                kind: .bash,
                profile: .legacyBashLogin,
                context: context,
                script: command,
                canonicalWorkingDirectory: workingDirectory,
                timeout: .seconds(min(min(timeoutSeconds, 120), limits.maximumTimeoutSeconds)),
                maximumInlineOutputBytes: min(
                    context.authorizationScope.maximumInlineOutputBytes,
                    limits.maximumInlineOutputBytes
                ),
                replayClass: replayClass,
                idempotencyKey: idempotencyKey
            )
        }
        return try await submit(request)
    }

    public func status(jobID: UUID, context: ToolInvocationContext) async throws -> RuntimeJobRecord {
        try Task.checkCancellation()
        try await ensureStarted()
        try await contextValidator.validateCaller(context)
        let record = try await repository.job(jobID, context: context)
        try Task.checkCancellation()
        return record
    }

    public func list(
        context: ToolInvocationContext,
        states: Set<RuntimeJobState> = [],
        limit: Int = 20,
        beforeCreatedAt: String? = nil
    ) async throws -> [RuntimeJobRecord] {
        try Task.checkCancellation()
        try await ensureStarted()
        try await contextValidator.validateCaller(context)
        let records = try await repository.list(
            context: context,
            states: states,
            limit: limit,
            beforeCreatedAt: beforeCreatedAt
        )
        try Task.checkCancellation()
        return records
    }

    public func readOutput(
        jobID: UUID,
        stream: RuntimeOutputStream,
        offset: UInt64,
        limit: Int,
        context: ToolInvocationContext
    ) async throws -> RuntimeOutputSlice {
        try Task.checkCancellation()
        try await ensureStarted()
        try await contextValidator.validateCaller(context)
        guard (1...(64 * 1_024)).contains(limit) else {
            throw RuntimeJobError.invalidRequest("output read limit must be between 1 and 65536 bytes")
        }
        let metadata = try await repository.output(jobID: jobID, stream: stream, context: context)
        if metadata.artifactEvicted {
            throw RuntimeJobError.artifactEvicted(jobID, stream)
        }
        let source: Data
        if let relativePath = metadata.artifactRelativePath {
            guard let artifact = try? artifactURL(relativePath) else {
                throw RuntimeJobError.artifactEvicted(jobID, stream)
            }
            source = try readVerifiedArtifact(
                artifact,
                metadata: metadata,
                offset: offset,
                limit: limit
            )
        } else {
            let bytes = Data(metadata.inlineText.utf8)
            let start = min(Int(min(offset, UInt64(Int.max))), bytes.count)
            source = Data(bytes[start..<min(bytes.count, start + limit)])
        }
        try Task.checkCancellation()
        let next = min(
            metadata.retainedByteCount,
            offset.addingReportingOverflow(UInt64(source.count)).overflow
                ? UInt64.max
                : offset + UInt64(source.count)
        )
        return RuntimeOutputSlice(
            jobID: jobID,
            stream: stream,
            offset: offset,
            data: source,
            nextOffset: next,
            totalRetainedBytes: metadata.retainedByteCount,
            totalObservedBytes: metadata.byteCount,
            eof: next >= metadata.retainedByteCount,
            artifactTruncated: metadata.artifactTruncated,
            sha256: metadata.sha256
        )
    }

    public func cancel(jobID: UUID, context: ToolInvocationContext) async throws {
        _ = try await cancelAndReturnRecord(jobID: jobID, context: context)
    }

    func cancelAndReturnRecord(
        jobID: UUID,
        context: ToolInvocationContext,
        commitObserver: (@Sendable (RuntimeJobRecord) -> Void)? = nil
    ) async throws -> RuntimeJobRecord {
        try Task.checkCancellation()
        try await ensureStarted()
        try await contextValidator.validateCaller(context)
        try Task.checkCancellation()
        return try await cancelOwnedJob(
            jobID: jobID,
            context: context,
            commitObserver: commitObserver
        ).record
    }

    /// Trusted manager seam that resolves the exact durable runtime-job binding.
    /// Callers provide no project, run, generation, or authorization scope to forge.
    func cancelStoredJob(jobID: UUID) async throws -> RuntimeJobRecord {
        try Task.checkCancellation()
        try await ensureStarted()
        guard try await repository.job(jobID) != nil else {
            throw RuntimeJobError.jobNotFound(jobID)
        }
        let context = try await contextValidator.contextForStoredJob(jobID: jobID)
        try await contextValidator.validateJob(jobID: jobID, context: context)
        try Task.checkCancellation()
        return try await cancelOwnedJob(jobID: jobID, context: context).record
    }

    /// Trusted manager seam for releasing the bounded set of queued and active jobs owned by a run.
    @discardableResult
    func cancelJobs(runID: RunID) async throws -> Int {
        try await ensureStarted()
        let configuredMaximum = limits.maximumQueuedJobs.addingReportingOverflow(
            limits.maximumConcurrentJobs
        )
        let maximumCandidates = configuredMaximum.overflow
            ? Int.max
            : configuredMaximum.partialValue
        var candidates: [(jobID: UUID, context: ToolInvocationContext)] = pending.compactMap {
            jobID, item in
            item.jobContext.runID == runID ? (jobID, item.jobContext) : nil
        }
        candidates.append(contentsOf: active.compactMap { jobID, execution in
            execution.jobContext.runID == runID ? (jobID, execution.jobContext) : nil
        })
        candidates.sort { $0.jobID.uuidString < $1.jobID.uuidString }
        if candidates.count > maximumCandidates {
            candidates.removeSubrange(maximumCandidates...)
        }

        var cancellationCount = 0
        var activeCandidates: Set<UUID> = []
        for candidate in candidates {
            if active[candidate.jobID] != nil { activeCandidates.insert(candidate.jobID) }
            if try await cancelOwnedJob(
                jobID: candidate.jobID,
                context: candidate.context
            ).changed {
                cancellationCount += 1
            }
        }
        let boundedTerminationGrace = min(limits.terminationGraceMilliseconds, 10_000)
        let boundedForcedGrace = min(limits.forcedTerminationGraceMilliseconds, 3_000)
        let maximumWaitMilliseconds = min(
            10_000,
            max(
                250,
                boundedTerminationGrace
                    + (boundedForcedGrace * 3)
                    + 500
            )
        )
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(maximumWaitMilliseconds)
        while activeCandidates.contains(where: { active[$0] != nil }) {
            guard clock.now < deadline else {
                throw RuntimeJobError.storageFailure(
                    "run-scoped runtime cancellation did not release all active jobs within its deadline"
                )
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cancellationCount
    }

    private func cancelOwnedJob(
        jobID: UUID,
        context: ToolInvocationContext,
        commitObserver: (@Sendable (RuntimeJobRecord) -> Void)? = nil
    ) async throws -> (changed: Bool, record: RuntimeJobRecord) {
        let record = try await repository.requestCancellation(
            jobID: jobID,
            context: context,
            commitObserver: commitObserver
        )
        if record.state == .cancelled, let pendingExecution = pending.removeValue(forKey: jobID) {
            pendingOrder.removeAll { $0 == jobID }
            pendingExecution.spool.discard()
            deleteRequestArtifact(pendingExecution.requestArtifactRelativePath)
            releaseArtifactReservation(jobID: jobID)
            pumpQueue()
            return (true, record)
        }
        if var execution = active[jobID] {
            execution.cancellationRequested = true
            active[jobID] = execution
            return (true, record)
        }
        return (false, record)
    }

    public func waitForTerminal(
        jobID: UUID,
        context: ToolInvocationContext,
        maximumWait: Duration
    ) async throws -> RuntimeJobRecord {
        let components = maximumWait.components
        guard components.seconds >= 0 else {
            throw RuntimeJobError.invalidRequest("maximum wait cannot be negative")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + maximumWait
        while true {
            let record = try await status(jobID: jobID, context: context)
            if record.state.isTerminal,
               active[jobID] == nil,
               pending[jobID] == nil {
                return record
            }
            guard clock.now < deadline else { return record }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @discardableResult
    public func shutdown() async -> RuntimeJobShutdownReport {
        shuttingDown = true
        let pendingIDs = pendingOrder
        for jobID in pendingIDs {
            guard let item = pending[jobID] else { continue }
            item.spool.discard()
            deleteRequestArtifact(item.requestArtifactRelativePath)
            let persisted = await persistTerminal(
                jobID: jobID,
                state: .cancelled,
                exitCode: nil,
                outputs: [],
                artifactID: nil,
                errorCode: "runtime_shutdown",
                errorSummary: "Runtime job service shut down before launch",
                expectedContext: item.jobContext
            )
            if persisted {
                pending.removeValue(forKey: jobID)
                pendingOrder.removeAll { $0 == jobID }
            }
        }
        for jobID in Array(active.keys) {
            if var execution = active[jobID] {
                _ = try? await repository.requestCancellation(
                    jobID: jobID,
                    context: execution.jobContext
                )
                execution.cancellationRequested = true
                if let process = execution.process,
                   execution.pendingTerminationCompletion == nil {
                    execution.pendingTerminationCompletion = PendingTerminationCompletion(
                        item: execution.item,
                        terminalState: .cancelled,
                        exitCode: process.currentExit()?.exitCode,
                        errorCode: "runtime_shutdown",
                        errorSummary: "Runtime job service shut down while the process was active"
                    )
                    execution.terminalPersistenceFailure = "termination pending: runtime shutdown"
                    terminationRecoveryJobs.insert(jobID)
                }
                active[jobID] = execution
                if execution.pendingTerminationCompletion != nil {
                    scheduleTerminationRecovery(jobID: jobID)
                }
            }
        }
        let maximumWaitMilliseconds = min(
            30_000,
            max(
                500,
                limits.terminationGraceMilliseconds
                    + (limits.forcedTerminationGraceMilliseconds * 3)
                    + 2_000
            )
        )
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(maximumWaitMilliseconds)
        while clock.now < deadline {
            await retryPendingTerminalWrites(maximumJobs: limits.maximumConcurrentJobs)
            for jobID in terminationRecoveryJobs where terminationRecoveryTasks[jobID] == nil {
                scheduleTerminationRecovery(jobID: jobID)
            }
            if pending.isEmpty,
               active.isEmpty,
               persistenceRecoveryJobs.isEmpty,
               terminationRecoveryJobs.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let durableNonterminal = (try? await repository.nonterminalJobs()) ?? []
        let unresolved = Set(pending.keys)
            .union(active.keys)
            .union(durableNonterminal.map(\.jobID))
            .union(terminationRecoveryJobs)
        let persistencePending = Set(persistenceRecoveryJobs)
        return RuntimeJobShutdownReport(
            completed: unresolved.isEmpty && persistencePending.isEmpty,
            unresolvedJobIDs: unresolved.sorted { $0.uuidString < $1.uuidString },
            persistencePendingJobIDs: persistencePending.sorted { $0.uuidString < $1.uuidString }
        )
    }

    // MARK: - Scheduling and execution

    private func ensureStarted() async throws {
        if !started { try await start() }
        await retryPendingTerminalWrites(maximumJobs: limits.maximumConcurrentJobs)
    }

    private func pumpQueue() {
        guard !shuttingDown else { return }
        while active.count < limits.maximumConcurrentJobs {
            let activeHeavy = active.values.lazy.filter(\.cpuHeavy).count
            guard let index = pendingOrder.firstIndex(where: { jobID in
                guard let item = pending[jobID] else { return false }
                return !item.cpuHeavy || activeHeavy < limits.maximumCPUHeavyJobs
            }) else { return }
            let jobID = pendingOrder.remove(at: index)
            guard let item = pending.removeValue(forKey: jobID) else { continue }
            let task = Task { await self.execute(jobID: jobID, pending: item) }
            active[jobID] = ActiveExecution(
                task: task,
                cpuHeavy: item.cpuHeavy,
                jobContext: item.jobContext,
                item: item,
                process: nil,
                cancellationRequested: false,
                terminalPersistenceFailure: nil,
                pendingTerminationCompletion: nil
            )
        }
    }

    private func execute(jobID: UUID, pending item: PendingExecution) async {
        var launchedProcess: RuntimeActiveProcess?
        do {
            try await contextValidator.validateJob(jobID: jobID, context: item.jobContext)
            if active[jobID]?.cancellationRequested == true {
                item.spool.discard()
                deleteRequestArtifact(item.requestArtifactRelativePath)
                let persisted = await persistTerminal(
                    jobID: jobID,
                    state: .cancelled,
                    exitCode: nil,
                    outputs: [],
                    artifactID: nil,
                    errorCode: "runtime_cancelled_before_launch",
                    errorSummary: "Runtime job was cancelled before process launch",
                    expectedContext: item.jobContext
                )
                if persisted { finish(jobID: jobID) }
                return
            }
            let process = try RuntimeActiveProcess(
                plan: item.plan,
                spool: item.spool,
                launcher: launcherURL
            )
            launchedProcess = process
            if var execution = active[jobID] {
                execution.process = process
                active[jobID] = execution
            }
            try await repository.markRunning(
                jobID: jobID,
                processIdentifier: process.processIdentifier,
                processGroupIdentifier: process.processGroupIdentifier,
                processStartIdentity: process.processStartIdentity
            )
            guard let startIdentity = process.processStartIdentity,
                  try await repository.recoveryProcessIdentity(jobID: jobID)
                    == RuntimePersistedProcessIdentity(
                        processIdentifier: process.processIdentifier,
                        processGroupIdentifier: process.processGroupIdentifier,
                        startIdentity: startIdentity
                    ) else {
                throw RuntimeJobError.storageFailure(
                    "runtime process identity could not be read back before launch-gate release"
                )
            }
            await launchObserver.processDidSpawn(
                jobID: jobID,
                processIdentifier: process.processIdentifier
            )
            if active[jobID]?.cancellationRequested == true {
                process.abortBeforeExecution()
                throw RuntimeJobError.invalidRequest(
                    "runtime job was cancelled before launch-gate release"
                )
            }
            try process.releaseForExecution()
            guard var execution = active[jobID] else {
                throw RuntimeJobError.storageFailure(
                    "runtime process ownership disappeared before execution"
                )
            }
            execution.process = process
            active[jobID] = execution
        } catch let launchError {
            if let launchedProcess {
                launchedProcess.abortBeforeExecution()
                do {
                    try await terminateLaunchedProcess(
                        jobID: jobID,
                        process: launchedProcess
                    )
                } catch {
                    let cancelled = active[jobID]?.cancellationRequested == true
                    retainTerminationOwnership(
                        jobID: jobID,
                        error: error,
                        completion: PendingTerminationCompletion(
                            item: item,
                            terminalState: cancelled ? .cancelled : .failed,
                            exitCode: launchedProcess.currentExit()?.exitCode,
                            errorCode: cancelled
                                ? "runtime_cancelled_during_launch"
                                : ((launchError as? RuntimeJobError)?.code ?? "runtime_launch_failed"),
                            errorSummary: cancelled
                                ? "Runtime job was cancelled while process launch was being committed"
                                : launchError.localizedDescription
                        )
                    )
                    return
                }
                let readersFinished = await launchedProcess.waitForReaders(
                    maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
                )
                if !readersFinished { launchedProcess.forceCloseReaders() }
            }
            let current = try? await repository.job(jobID)
            let persisted: Bool
            if current?.state.isTerminal == true {
                item.spool.discard()
                deleteRequestArtifact(item.requestArtifactRelativePath)
                releaseArtifactReservation(jobID: jobID)
                persisted = true
            } else if active[jobID]?.cancellationRequested == true {
                item.spool.discard()
                deleteRequestArtifact(item.requestArtifactRelativePath)
                persisted = await persistTerminal(
                    jobID: jobID,
                    state: .cancelled,
                    exitCode: launchedProcess?.currentExit()?.exitCode,
                    outputs: [],
                    artifactID: nil,
                    errorCode: "runtime_cancelled_during_launch",
                    errorSummary: "Runtime job was cancelled while process launch was being committed",
                    expectedContext: item.jobContext
                )
            } else {
                persisted = await recordLaunchFailure(
                    jobID: jobID,
                    pending: item,
                    error: launchError
                )
            }
            if persisted { finish(jobID: jobID) }
            return
        }
        guard let process = launchedProcess else {
            let persisted = await recordLaunchFailure(
                jobID: jobID,
                pending: item,
                error: RuntimeJobError.storageFailure(
                    "runtime process launch completed without an owned process"
                )
            )
            if persisted { finish(jobID: jobID) }
            return
        }

        let timeoutSeconds = (try? Self.timeoutSeconds(
            item.request.timeout,
            maximum: limits.maximumTimeoutSeconds
        )) ?? 1
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeoutSeconds)
        var exit: RuntimeProcessExit?
        var timedOut = false
        var cancellationObserved = false
        var descendantLimitExceeded = false
        var terminationFailure: Error?
        while exit == nil {
            if active[jobID]?.pendingTerminationCompletion != nil {
                return
            }
            if Self.processGroupExceedsDescendantLimit(
                processGroupIdentifier: process.processGroupIdentifier,
                maximumDescendants: limits.maximumDescendantProcessesPerJob
            ) {
                descendantLimitExceeded = true
                do {
                    try await terminateLaunchedProcess(jobID: jobID, process: process)
                    exit = process.currentExit()
                    if exit == nil {
                        exit = await process.waitForExit(
                            maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
                        )
                    }
                } catch {
                    terminationFailure = error
                }
                break
            }
            if let current = process.currentExit() {
                exit = current
                break
            }
            if active[jobID]?.cancellationRequested == true {
                cancellationObserved = true
                do {
                    try await terminateLaunchedProcess(jobID: jobID, process: process)
                    exit = process.currentExit()
                    if exit == nil {
                        exit = await process.waitForExit(
                            maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
                        )
                    }
                } catch {
                    terminationFailure = error
                }
                break
            }
            if clock.now >= deadline {
                timedOut = true
                do {
                    try await terminateLaunchedProcess(jobID: jobID, process: process)
                    exit = process.currentExit()
                    if exit == nil {
                        exit = await process.waitForExit(
                            maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
                        )
                    }
                } catch {
                    terminationFailure = error
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !cancellationObserved, !timedOut, !descendantLimitExceeded {
            do {
                try await terminateLaunchedProcess(jobID: jobID, process: process)
            } catch {
                terminationFailure = error
            }
        }
        if let terminationFailure {
            let terminalState: RuntimeJobState
            let errorCode: String
            let errorSummary: String
            if cancellationObserved || active[jobID]?.cancellationRequested == true {
                terminalState = .cancelled
                errorCode = "runtime_cancelled_termination_pending"
                errorSummary = "Runtime cancellation is waiting for owned process-group death"
            } else if timedOut {
                terminalState = .timedOut
                errorCode = "runtime_timeout_termination_pending"
                errorSummary = "Runtime timeout is waiting for owned process-group death"
            } else if descendantLimitExceeded {
                terminalState = .failed
                errorCode = "runtime_descendant_limit_exceeded"
                errorSummary = "Runtime process group exceeded its descendant-process budget"
            } else {
                terminalState = .failed
                errorCode = "runtime_termination_unconfirmed"
                errorSummary = "Runtime completion is waiting for owned process-group death"
            }
            retainTerminationOwnership(
                jobID: jobID,
                error: terminationFailure,
                completion: PendingTerminationCompletion(
                    item: item,
                    terminalState: terminalState,
                    exitCode: exit?.exitCode,
                    errorCode: errorCode,
                    errorSummary: errorSummary
                )
            )
            return
        }
        let readersFinished = await process.waitForReaders(
            maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
        )
        if !readersFinished {
            process.forceCloseReaders()
            _ = await process.waitForReaders(
                maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
            )
        }

        let outputs: [RuntimeJobOutputMetadata]
        do {
            outputs = try item.spool.finalize()
        } catch {
            item.spool.discard()
            deleteRequestArtifact(item.requestArtifactRelativePath)
            let persisted = await persistTerminal(
                jobID: jobID,
                state: .failed,
                exitCode: exit?.exitCode,
                outputs: [],
                artifactID: nil,
                errorCode: RuntimeJobError.storageFailure(error.localizedDescription).code,
                errorSummary: error.localizedDescription,
                expectedContext: item.jobContext
            )
            if persisted { finish(jobID: jobID) }
            return
        }
        deleteRequestArtifact(item.requestArtifactRelativePath)

        let wasCancelled = cancellationObserved || active[jobID]?.cancellationRequested == true
        let state: RuntimeJobState
        if wasCancelled {
            state = .cancelled
        } else if timedOut {
            state = .timedOut
        } else if descendantLimitExceeded {
            state = .failed
        } else if exit?.exitCode == 0 {
            state = .completed
        } else {
            state = .failed
        }
        let resultSHA = JSONSupport.sha256Hex(
            outputs.sorted { $0.stream.rawValue < $1.stream.rawValue }
                .map { "\($0.stream.rawValue):\($0.sha256):\($0.byteCount)" }
                .joined(separator: "|")
        )
        do {
            try await contextValidator.commitJobResult(
                jobID: jobID,
                context: item.jobContext,
                resultSHA256: resultSHA
            )
            _ = await persistTerminal(
                jobID: jobID,
                state: state,
                exitCode: exit?.exitCode,
                outputs: outputs,
                artifactID: outputs.contains(where: { $0.artifactRelativePath != nil })
                    ? item.spool.artifactID : nil,
                errorCode: descendantLimitExceeded
                    ? "runtime_descendant_limit_exceeded"
                    : (state == .failed ? "runtime_exit_nonzero" : nil),
                errorSummary: descendantLimitExceeded
                    ? "Runtime process group exceeded its descendant-process budget"
                    : (state == .failed ? "Process exited with code \(exit?.exitCode ?? 255)" : nil),
                expectedContext: item.jobContext
            )
        } catch let error as ProjectContextError {
            _ = await persistTerminal(
                jobID: jobID,
                state: .quarantinedStale,
                exitCode: exit?.exitCode,
                outputs: outputs,
                artifactID: outputs.contains(where: { $0.artifactRelativePath != nil })
                    ? item.spool.artifactID : nil,
                errorCode: error.code,
                errorSummary: "Runtime result was fenced by the current project context",
                expectedContext: item.jobContext
            )
        } catch {
            _ = await persistTerminal(
                jobID: jobID,
                state: .failed,
                exitCode: exit?.exitCode,
                outputs: outputs,
                artifactID: outputs.contains(where: { $0.artifactRelativePath != nil })
                    ? item.spool.artifactID : nil,
                errorCode: "runtime_context_validation_failed",
                errorSummary: error.localizedDescription,
                expectedContext: item.jobContext
            )
        }
        if active[jobID]?.terminalPersistenceFailure == nil {
            finish(jobID: jobID)
        }
    }

    private func recordLaunchFailure(
        jobID: UUID,
        pending item: PendingExecution,
        error: Error
    ) async -> Bool {
        let outputs: [RuntimeJobOutputMetadata]
        do {
            outputs = try item.spool.finalize()
        } catch {
            item.spool.discard()
            outputs = []
        }
        deleteRequestArtifact(item.requestArtifactRelativePath)
        let persisted = await persistTerminal(
            jobID: jobID,
            state: .failed,
            exitCode: nil,
            outputs: outputs,
            artifactID: nil,
            errorCode: (error as? RuntimeJobError)?.code ?? "runtime_launch_failed",
            errorSummary: error.localizedDescription,
            expectedContext: item.jobContext
        )
        return persisted
    }

    private func persistTerminal(
        jobID: UUID,
        state: RuntimeJobState,
        exitCode: Int32?,
        outputs: [RuntimeJobOutputMetadata],
        artifactID: String?,
        errorCode: String?,
        errorSummary: String?,
        expectedContext: ToolInvocationContext?
    ) async -> Bool {
        let payload = TerminalPersistencePayload(
            jobID: jobID,
            state: state,
            exitCode: exitCode,
            outputs: outputs,
            artifactID: artifactID,
            errorCode: errorCode,
            errorSummary: errorSummary,
            expectedContext: expectedContext
        )
        var lastError: Error?
        for attempt in 0..<3 {
            let result = await attemptTerminalPersistence(payload)
            if result.persisted { return true }
            lastError = result.error
            if attempt == 2 { break }
            try? await Task.sleep(for: .milliseconds(25 * (attempt + 1)))
        }
        retainForRecovery(
            payload: payload,
            error: lastError?.localizedDescription ?? "terminal persistence failed"
        )
        return false
    }

    private func attemptTerminalPersistence(
        _ payload: TerminalPersistencePayload
    ) async -> (persisted: Bool, error: Error?) {
        do {
            try await terminalPersistenceHook.beforeTerminalPersistence(jobID: payload.jobID)
            _ = try await repository.complete(
                jobID: payload.jobID,
                terminalState: payload.state,
                exitCode: payload.exitCode,
                outputs: payload.outputs,
                artifactID: payload.artifactID,
                errorCode: payload.errorCode,
                errorSummary: payload.errorSummary,
                expectedContext: payload.expectedContext
            )
            await settleArtifactReservation(jobID: payload.jobID)
            return (true, nil)
        } catch {
            if let current = try? await repository.job(payload.jobID),
               current.state.isTerminal {
                await settleArtifactReservation(jobID: payload.jobID)
                return (true, nil)
            }
            return (false, error)
        }
    }

    private func retainForRecovery(payload: TerminalPersistencePayload, error: String) {
        let jobID = payload.jobID
        persistenceRecoveryJobs.insert(jobID)
        persistenceRecoveryPayloads[jobID] = payload
        schedulePersistenceRecovery(jobID: jobID)
        guard var execution = active[jobID] else { return }
        execution.process = nil
        execution.terminalPersistenceFailure = String(error.prefix(2_048))
        active[jobID] = execution
    }

    private func retainTerminationOwnership(
        jobID: UUID,
        error: Error,
        completion: PendingTerminationCompletion
    ) {
        guard var execution = active[jobID] else { return }
        execution.cancellationRequested = true
        execution.terminalPersistenceFailure = String(
            "termination pending: \(error.localizedDescription)".prefix(2_048)
        )
        execution.pendingTerminationCompletion = completion
        active[jobID] = execution
        terminationRecoveryJobs.insert(jobID)
        scheduleTerminationRecovery(jobID: jobID)
    }

    private func scheduleTerminationRecovery(jobID: UUID, delayMilliseconds: Int = 0) {
        guard terminationRecoveryTasks[jobID] == nil else { return }
        terminationRecoveryTasks[jobID] = Task {
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            await self.runTerminationRecovery(jobID: jobID)
        }
    }

    private func runTerminationRecovery(jobID: UUID) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        var delay = 25
        while clock.now < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(delay))
            guard let execution = active[jobID],
                  let process = execution.process,
                  let completion = execution.pendingTerminationCompletion,
                  let identity = Self.persistedIdentity(for: process) else { break }
            do {
                _ = try await reapPersistedProcessGroup(jobID: jobID, identity: identity)
                _ = await process.waitForExit(
                    maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
                )
                await completeTerminationRecovery(
                    jobID: jobID,
                    process: process,
                    completion: completion
                )
                break
            } catch {
                updateTerminationRecoveryError(jobID: jobID, error: error)
            }
            delay = min(1_000, delay * 2)
        }
        terminationRecoveryTasks.removeValue(forKey: jobID)
        if terminationRecoveryJobs.contains(jobID), active[jobID] != nil {
            scheduleTerminationRecovery(jobID: jobID, delayMilliseconds: 1_000)
        }
    }

    private func updateTerminationRecoveryError(jobID: UUID, error: Error) {
        guard var execution = active[jobID] else { return }
        execution.terminalPersistenceFailure = String(
            "termination pending: \(error.localizedDescription)".prefix(2_048)
        )
        active[jobID] = execution
    }

    private func completeTerminationRecovery(
        jobID: UUID,
        process: RuntimeActiveProcess,
        completion: PendingTerminationCompletion
    ) async {
        let readersFinished = await process.waitForReaders(
            maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
        )
        if !readersFinished {
            process.forceCloseReaders()
            _ = await process.waitForReaders(
                maximumMilliseconds: limits.forcedTerminationGraceMilliseconds
            )
        }
        let outputs: [RuntimeJobOutputMetadata]
        do {
            outputs = try completion.item.spool.finalize()
        } catch {
            completion.item.spool.discard()
            outputs = []
        }
        deleteRequestArtifact(completion.item.requestArtifactRelativePath)

        var terminalState = completion.terminalState
        var errorCode = completion.errorCode
        var errorSummary = completion.errorSummary
        let resultSHA = JSONSupport.sha256Hex(
            outputs.sorted { $0.stream.rawValue < $1.stream.rawValue }
                .map { "\($0.stream.rawValue):\($0.sha256):\($0.byteCount)" }
                .joined(separator: "|")
        )
        do {
            try await contextValidator.commitJobResult(
                jobID: jobID,
                context: completion.item.jobContext,
                resultSHA256: resultSHA
            )
        } catch let error as ProjectContextError {
            terminalState = .quarantinedStale
            errorCode = error.code
            errorSummary = "Runtime result was fenced by the current project context"
        } catch {
            terminalState = .failed
            errorCode = "runtime_context_validation_failed"
            errorSummary = error.localizedDescription
        }

        if var execution = active[jobID] {
            execution.process = nil
            execution.pendingTerminationCompletion = nil
            execution.terminalPersistenceFailure = nil
            active[jobID] = execution
        }
        terminationRecoveryJobs.remove(jobID)
        let persisted = await persistTerminal(
            jobID: jobID,
            state: terminalState,
            exitCode: completion.exitCode ?? process.currentExit()?.exitCode,
            outputs: outputs,
            artifactID: outputs.contains(where: { $0.artifactRelativePath != nil })
                ? completion.item.spool.artifactID : nil,
            errorCode: errorCode,
            errorSummary: errorSummary,
            expectedContext: completion.item.jobContext
        )
        if persisted { finish(jobID: jobID) }
    }

    private func schedulePersistenceRecovery(jobID: UUID) {
        guard persistenceRecoveryTasks[jobID] == nil else { return }
        persistenceRecoveryTasks[jobID] = Task { await self.runPersistenceRecovery(jobID: jobID) }
    }

    private func runPersistenceRecovery(jobID: UUID) async {
        let delays = [50, 100, 200, 400, 800]
        for delay in delays {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(delay))
            guard let payload = persistenceRecoveryPayloads[jobID] else { break }
            let result = await attemptTerminalPersistence(payload)
            if result.persisted {
                completePersistenceRecovery(jobID: jobID)
                break
            }
            updatePersistenceRecoveryError(jobID: jobID, error: result.error)
        }
        persistenceRecoveryTasks.removeValue(forKey: jobID)
    }

    private func retryPendingTerminalWrites(maximumJobs: Int) async {
        let boundedMaximum = min(max(1, maximumJobs), limits.maximumConcurrentJobs)
        let jobIDs = persistenceRecoveryJobs
            .sorted { $0.uuidString < $1.uuidString }
            .prefix(boundedMaximum)
        for jobID in jobIDs {
            guard let payload = persistenceRecoveryPayloads[jobID] else { continue }
            let result = await attemptTerminalPersistence(payload)
            if result.persisted {
                persistenceRecoveryTasks[jobID]?.cancel()
                completePersistenceRecovery(jobID: jobID)
            } else {
                updatePersistenceRecoveryError(jobID: jobID, error: result.error)
                schedulePersistenceRecovery(jobID: jobID)
            }
        }
    }

    private func updatePersistenceRecoveryError(jobID: UUID, error: Error?) {
        guard var execution = active[jobID] else { return }
        execution.terminalPersistenceFailure = String(
            (error?.localizedDescription ?? "terminal persistence failed").prefix(2_048)
        )
        active[jobID] = execution
    }

    private func completePersistenceRecovery(jobID: UUID) {
        persistenceRecoveryJobs.remove(jobID)
        persistenceRecoveryPayloads.removeValue(forKey: jobID)
        if active[jobID] != nil { finish(jobID: jobID) }
    }

    private func reserveArtifactCapacity(
        jobID: UUID,
        request: RuntimeJobRequest
    ) async throws -> Int {
        await compactArtifacts(projectID: request.context.projectID)
        let projectID = request.context.projectID
        let requestBytes = request.profile == .directProcess
            ? UInt64(0)
            : UInt64(request.script?.utf8.count ?? 0)
        let persistedGlobal = try await repository.retainedArtifactBytes()
        let persistedProject = try await repository.retainedArtifactBytes(projectID: projectID)
        let reservedGlobal = artifactReservations.values.reduce(UInt64(0)) {
            Self.saturatingAdd($0, $1.totalBytes)
        }
        let reservedProject = artifactReservations.values.lazy
            .filter { $0.projectID == projectID }
            .reduce(UInt64(0)) { Self.saturatingAdd($0, $1.totalBytes) }
        let globalRemaining = Self.remaining(
            limit: UInt64(limits.maximumArtifactBytesGlobal),
            used: Self.saturatingAdd(persistedGlobal, reservedGlobal)
        )
        let projectRemaining = Self.remaining(
            limit: UInt64(limits.maximumArtifactBytesPerProject),
            used: Self.saturatingAdd(persistedProject, reservedProject)
        )
        guard requestBytes <= globalRemaining, requestBytes <= projectRemaining else {
            throw RuntimeJobError.artifactQuotaExhausted(projectID)
        }
        let outputBytes = min(
            UInt64(limits.maximumArtifactBytesPerJob),
            min(globalRemaining - requestBytes, projectRemaining - requestBytes)
        )
        artifactReservations[jobID] = ArtifactReservation(
            projectID: projectID,
            requestBytes: requestBytes,
            outputBytes: outputBytes
        )
        return Int(min(outputBytes, UInt64(Int.max)))
    }

    private func releaseArtifactReservation(jobID: UUID) {
        artifactReservations.removeValue(forKey: jobID)
    }

    private func settleArtifactReservation(jobID: UUID) async {
        let projectID = artifactReservations.removeValue(forKey: jobID)?.projectID
        persistenceRecoveryJobs.remove(jobID)
        persistenceRecoveryPayloads.removeValue(forKey: jobID)
        if let projectID { await compactArtifacts(projectID: projectID) }
        await compactTerminalLedger()
    }

    private func compactTerminalLedger() async {
        _ = try? await repository.compactTerminalJobs()
    }

    private func compactArtifacts(projectID: ProjectID?) async {
        let maximumEvictions = 64
        for _ in 0..<maximumEvictions {
            do {
                let globalBytes = try await repository.retainedArtifactBytes()
                let globalOverQuota = globalBytes > UInt64(limits.maximumArtifactBytesGlobal)
                var projectOverQuota = false
                var projectOverCount = false
                if let projectID {
                    projectOverQuota = try await repository.retainedArtifactBytes(projectID: projectID)
                        > UInt64(limits.maximumArtifactBytesPerProject)
                    projectOverCount = try await repository.retainedArtifactJobCount(projectID: projectID)
                        > limits.maximumRetainedArtifactJobsPerProject
                }
                guard globalOverQuota || projectOverQuota || projectOverCount else { return }
                let scope = (projectOverQuota || projectOverCount) ? projectID : nil
                guard let candidate = try await repository.oldestArtifactCandidates(
                    projectID: scope,
                    limit: 1
                ).first else { return }
                guard await evictArtifact(candidate) else { return }
            } catch {
                return
            }
        }
    }

    private func evictArtifact(_ candidate: RuntimeArtifactRetentionCandidate) async -> Bool {
        let url: URL
        do {
            url = try artifactURL(candidate.relativePath)
        } catch {
            return (try? await repository.markArtifactEvicted(
                jobID: candidate.jobID,
                stream: candidate.stream
            )) == true
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return false
            }
        }
        do {
            guard try await repository.markArtifactEvicted(
                jobID: candidate.jobID,
                stream: candidate.stream
            ) else { return false }
            let directory = url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
            return true
        } catch {
            return false
        }
    }

    private static func remaining(limit: UInt64, used: UInt64) -> UInt64 {
        used >= limit ? 0 : limit - used
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private static func recoverySignalSummary(
        termination: RuntimeRecoveredProcessSignalResult,
        forced: RuntimeRecoveredProcessSignalResult?
    ) -> String {
        if let forced {
            return "; recovered SIGTERM \(signalDescription(termination)); SIGKILL \(signalDescription(forced))"
        }
        return "; no recovered kill was sent after \(signalDescription(termination))"
    }

    private static func signalDescription(_ result: RuntimeRecoveredProcessSignalResult) -> String {
        switch result {
        case .signaled: "signaled"
        case .processMissing: "process missing"
        case .identityUnavailable: "identity unavailable"
        case .identityMismatch: "identity mismatch"
        case .signalFailed(let error): "signal failed with errno \(error)"
        }
    }

    private static func persistedIdentity(
        for process: RuntimeActiveProcess
    ) -> RuntimePersistedProcessIdentity? {
        guard let startIdentity = process.processStartIdentity else { return nil }
        return RuntimePersistedProcessIdentity(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier,
            startIdentity: startIdentity
        )
    }

    private static func processGroupExceedsDescendantLimit(
        processGroupIdentifier: Int32,
        maximumDescendants: Int
    ) -> Bool {
        guard processGroupIdentifier > 1, maximumDescendants > 0 else { return true }
        let maximumMembers = maximumDescendants + 1
        var processIdentifiers = [pid_t](repeating: 0, count: maximumMembers + 1)
        let byteCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(bitPattern: processGroupIdentifier),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard byteCount > 0 else { return false }
        let returnedCount = min(
            processIdentifiers.count,
            Int(byteCount) / MemoryLayout<pid_t>.stride
        )
        return processIdentifiers.prefix(returnedCount).lazy.filter { $0 > 0 }.count
            > maximumMembers
    }

    private func finish(jobID: UUID) {
        active.removeValue(forKey: jobID)
        pumpQueue()
    }

    // MARK: - Request validation and planning

    private func validate(_ request: RuntimeJobRequest) throws -> (
        workingDirectory: URL,
        timeoutSeconds: Int,
        inlineBytes: Int
    ) {
        try Self.validateProfile(kind: request.kind, profile: request.profile)
        guard request.arguments.count <= limits.maximumArguments else {
            throw RuntimeJobError.invalidRequest("too many runtime arguments")
        }
        let argumentBytes = request.arguments.reduce(0) { partial, value in
            let sum = partial.addingReportingOverflow(value.utf8.count)
            return sum.overflow ? Int.max : sum.partialValue
        }
        guard argumentBytes <= limits.maximumArgumentBytes,
              request.arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw RuntimeJobError.invalidRequest("runtime arguments exceed their byte limit or contain NUL")
        }
        if let script = request.script {
            guard script.utf8.count <= limits.maximumScriptBytes, !script.contains("\0") else {
                throw RuntimeJobError.invalidRequest("runtime script exceeds its byte limit or contains NUL")
            }
        }
        guard request.maximumInlineOutputBytes > 0,
              request.context.authorizationScope.maximumInlineOutputBytes > 0 else {
            throw RuntimeJobError.invalidRequest("inline output limit must be positive")
        }
        let timeoutSeconds = try Self.timeoutSeconds(
            request.timeout,
            maximum: limits.maximumTimeoutSeconds
        )
        let inlineBytes = min(
            max(1, request.maximumInlineOutputBytes),
            min(limits.maximumInlineOutputBytes, request.context.authorizationScope.maximumInlineOutputBytes)
        )
        let cwd = try Self.authorizedWorkingDirectory(
            request.canonicalWorkingDirectory,
            roots: request.context.authorizationScope.canonicalRoots
        )
        try validateCapability(for: request.profile)
        return (cwd, timeoutSeconds, inlineBytes)
    }

    private func buildPlan(
        jobID: UUID,
        request: RuntimeJobRequest,
        canonicalWorkingDirectory: URL,
        spool: RuntimeOutputSpool
    ) throws -> (plan: RuntimeProcessPlan, summary: String, requestArtifactRelativePath: String?) {
        var environment = processEnvironment
        let requestedTimeout = try Self.timeoutSeconds(
            request.timeout,
            maximum: limits.maximumTimeoutSeconds
        )
        environment["FORGE_RUNTIME_LIMIT_CPU_SECONDS"] = String(
            min(limits.maximumCPUSecondsPerProcess, requestedTimeout + 2)
        )
        environment["FORGE_RUNTIME_LIMIT_OPEN_FILES"] = String(
            limits.maximumOpenFilesPerProcess
        )
        environment["FORGE_RUNTIME_LIMIT_FILE_BYTES"] = String(
            limits.maximumFileBytesPerProcess
        )
        environment["FORGE_RUNTIME_LIMIT_CORE_BYTES"] = String(
            limits.maximumCoreBytesPerProcess
        )
        let executable: URL
        let arguments: [String]
        let requestArtifact: String?
        switch request.profile {
        case .directProcess:
            guard let requested = request.executable else {
                throw RuntimeJobError.invalidRequest("process.run requires an executable")
            }
            executable = try Self.executableURL(requested)
            arguments = request.arguments
            requestArtifact = nil
        case .zshNoProfile:
            executable = try requiredCapabilityURL(discoveredCapabilities.zsh, name: "zsh")
            let script = try Self.requiredScript(request)
            requestArtifact = try stageScript(script, extension: "zsh", spool: spool)
            arguments = ["-f", artifactRoot.appendingPathComponent(requestArtifact!).path]
        case .bashNoProfile:
            executable = try requiredCapabilityURL(discoveredCapabilities.bash, name: "bash")
            let script = try Self.requiredScript(request)
            requestArtifact = try stageScript(script, extension: "bash", spool: spool)
            arguments = ["--noprofile", "--norc", artifactRoot.appendingPathComponent(requestArtifact!).path]
        case .legacyBashLogin:
            executable = try requiredCapabilityURL(discoveredCapabilities.bash, name: "bash")
            let script = try Self.requiredScript(request)
            requestArtifact = try stageScript(script, extension: "legacy-bash", spool: spool)
            arguments = ["-lc", script]
        case .pythonIsolated:
            executable = try requiredCapabilityURL(discoveredCapabilities.python, name: "python3")
            let script = try Self.requiredScript(request)
            requestArtifact = try stageScript(script, extension: "py", spool: spool)
            arguments = ["-I", "-B", artifactRoot.appendingPathComponent(requestArtifact!).path]
        case .powershellNoProfile:
            executable = try requiredCapabilityURL(discoveredCapabilities.powershell, name: "pwsh")
            let script = try Self.requiredScript(request)
            requestArtifact = try stageScript(script, extension: "ps1", spool: spool)
            arguments = [
                "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                artifactRoot.appendingPathComponent(requestArtifact!).path,
            ]
        }
        let summary = "\(request.profile.rawValue):\(executable.lastPathComponent):argv=\(arguments.count):script_bytes=\(request.script?.utf8.count ?? 0)"
        let sandboxedPlan = try RuntimeProcessSandbox.plan(
            executable: executable,
            arguments: arguments,
            workingDirectory: canonicalWorkingDirectory,
            environment: environment,
            canonicalReadRoots: request.context.authorizationScope.canonicalRoots,
            canonicalWritableRoots: request.context.authorizationScope.writableRoots,
            managerReadDirectory: spool.canonicalDirectory,
            scratchDirectory: spool.canonicalScratchDirectory,
            networkAllowed: request.context.authorizationScope.networkAllowed
        )
        return (
            sandboxedPlan,
            summary,
            requestArtifact
        )
    }

    private func stageScript(
        _ script: String,
        extension fileExtension: String,
        spool: RuntimeOutputSpool
    ) throws -> String {
        let relative = spool.relativeDirectory + "/request." + fileExtension
        let url = try artifactURL(relative)
        try Data(script.utf8).write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR)
        return relative
    }

    private func deleteRequestArtifact(_ relativePath: String?) {
        guard let relativePath, let url = try? artifactURL(relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func deleteInterruptedArtifacts(_ job: RuntimeJobRecord) throws {
        let relativeDirectory = [
            job.projectID.description,
            String(job.projectGeneration.rawValue),
            job.jobID.uuidString.lowercased(),
        ].joined(separator: "/")
        for relativePath in [relativeDirectory, ".runtime-scratch/" + relativeDirectory] {
            let directory = try artifactURL(relativePath)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw RuntimeJobError.storageFailure(
                    "could not remove interrupted runtime artifacts: \(error.localizedDescription)"
                )
            }
        }
    }

    private func sweepOrphanedJobDirectories() async throws {
        var remainingEntries = Self.maximumStartupDirectoryEntries
        var candidates: [JobDirectoryCandidate] = []
        try appendJobDirectoryCandidates(
            below: artifactRoot,
            remainingEntries: &remainingEntries,
            candidates: &candidates
        )
        let scratchRoot = artifactRoot.appendingPathComponent(".runtime-scratch", isDirectory: true)
        if candidates.count < Self.maximumStartupOrphanDirectories,
           remainingEntries > 0,
           FileManager.default.fileExists(atPath: scratchRoot.path) {
            try appendJobDirectoryCandidates(
                below: scratchRoot,
                remainingEntries: &remainingEntries,
                candidates: &candidates
            )
        }

        for candidate in candidates.prefix(Self.maximumStartupOrphanDirectories) {
            let record = try await repository.job(candidate.jobID)
            let isDurableIntent = record?.projectID == candidate.projectID
                && record?.projectGeneration == candidate.generation
            guard !isDurableIntent else { continue }
            let resolved = RuntimeProcessSandbox.canonicalExistingURL(candidate.url)
            guard resolved.path == candidate.url.path,
                  Self.contains(resolved, root: candidate.root) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: resolved)
            } catch {
                throw RuntimeJobError.storageFailure(
                    "could not remove orphaned runtime job directory: \(error.localizedDescription)"
                )
            }
        }
    }

    private func appendJobDirectoryCandidates(
        below root: URL,
        remainingEntries: inout Int,
        candidates: inout [JobDirectoryCandidate]
    ) throws {
        guard remainingEntries > 0,
              candidates.count < Self.maximumStartupOrphanDirectories,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: nil
              ) else { return }

        while remainingEntries > 0,
              candidates.count < Self.maximumStartupOrphanDirectories,
              let candidate = enumerator.nextObject() as? URL {
            remainingEntries -= 1
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isDirectory != true {
                if values.isSymbolicLink == true { enumerator.skipDescendants() }
                continue
            }
            let relative = String(candidate.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            if components.count < 3 { continue }
            if components.count > 3 {
                enumerator.skipDescendants()
                continue
            }
            enumerator.skipDescendants()
            guard let projectUUID = UUID(uuidString: String(components[0])),
                  let generationValue = UInt64(components[1]),
                  generationValue > 0,
                  let jobID = UUID(uuidString: String(components[2])) else {
                continue
            }
            candidates.append(JobDirectoryCandidate(
                url: candidate,
                root: root,
                projectID: ProjectID(projectUUID),
                generation: ProjectGeneration(generationValue),
                jobID: jobID
            ))
        }
    }

    private func readVerifiedArtifact(
        _ artifact: URL,
        metadata: RuntimeJobOutputMetadata,
        offset: UInt64,
        limit: Int
    ) throws -> Data {
        guard metadata.retainedByteCount <= UInt64(limits.maximumArtifactBytesPerJob) else {
            throw RuntimeJobError.storageFailure("runtime artifact exceeds its retained byte bound")
        }
        let descriptor = Darwin.open(artifact.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeJobError.artifactEvicted(metadata.jobID, metadata.stream)
        }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
              initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == Darwin.geteuid(),
              initial.st_nlink == 1,
              initial.st_size >= 0,
              UInt64(initial.st_size) == metadata.retainedByteCount,
              initial.st_dev >= 0 else {
            throw RuntimeJobError.storageFailure("runtime artifact metadata no longer matches")
        }
        if let expectedDevice = metadata.artifactDeviceIdentifier,
           expectedDevice != UInt64(initial.st_dev) {
            throw RuntimeJobError.storageFailure("runtime artifact device identity changed")
        }
        if let expectedFile = metadata.artifactFileIdentifier,
           expectedFile != UInt64(initial.st_ino) {
            throw RuntimeJobError.storageFailure("runtime artifact file identity changed")
        }
        guard (metadata.artifactDeviceIdentifier == nil)
                == (metadata.artifactFileIdentifier == nil) else {
            throw RuntimeJobError.storageFailure("runtime artifact identity is incomplete")
        }

        let sliceStart = min(offset, metadata.retainedByteCount)
        let requestedEnd = sliceStart.addingReportingOverflow(UInt64(limit))
        let sliceEnd = min(
            metadata.retainedByteCount,
            requestedEnd.overflow ? UInt64.max : requestedEnd.partialValue
        )
        var slice = Data()
        slice.reserveCapacity(Int(sliceEnd - sliceStart))
        var hasher = SHA256()
        var fileOffset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while fileOffset < metadata.retainedByteCount {
            let remaining = metadata.retainedByteCount - fileOffset
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(fileOffset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeJobError.storageFailure("runtime artifact changed during verification")
            }
            let data = Data(buffer.prefix(count))
            hasher.update(data: data)
            let chunkEnd = fileOffset + UInt64(count)
            let overlapStart = max(fileOffset, sliceStart)
            let overlapEnd = min(chunkEnd, sliceEnd)
            if overlapStart < overlapEnd {
                let lower = Int(overlapStart - fileOffset)
                let upper = Int(overlapEnd - fileOffset)
                slice.append(data[lower..<upper])
            }
            fileOffset = chunkEnd
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.sha256.lowercased() else {
            throw RuntimeJobError.storageFailure("runtime artifact SHA-256 verification failed")
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw RuntimeJobError.storageFailure("runtime artifact changed during verification")
        }
        return slice
    }

    private func artifactURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw RuntimeJobError.invalidRequest("artifact path must remain relative")
        }
        let url = artifactRoot.appendingPathComponent(relativePath)
        let resolved = RuntimeProcessSandbox.canonicalURL(url)
        guard resolved.path == url.path, Self.contains(resolved, root: artifactRoot) else {
            throw RuntimeJobError.invalidRequest("artifact path is not canonical")
        }
        return resolved
    }

    private func requiredCapabilityURL(
        _ capability: RuntimeExecutableCapability,
        name: String
    ) throws -> URL {
        guard capability.available, let path = capability.executablePath else {
            throw RuntimeJobError.executableUnavailable(name)
        }
        return URL(fileURLWithPath: path)
    }

    private func validateCapability(for profile: RuntimeExecutionProfile) throws {
        switch profile {
        case .directProcess:
            guard discoveredCapabilities.directProcess.available else {
                throw RuntimeJobError.executableUnavailable("sandbox-exec")
            }
        case .zshNoProfile:
            guard discoveredCapabilities.zsh.available else {
                throw RuntimeJobError.executableUnavailable("zsh")
            }
        case .bashNoProfile, .legacyBashLogin:
            guard discoveredCapabilities.bash.available else {
                throw RuntimeJobError.executableUnavailable("bash")
            }
        case .pythonIsolated:
            guard discoveredCapabilities.python.available else {
                throw RuntimeJobError.executableUnavailable("python3")
            }
        case .powershellNoProfile:
            guard discoveredCapabilities.powershell.available else {
                throw RuntimeJobError.executableUnavailable("pwsh")
            }
        }
    }

    private static func validateProfile(kind: RuntimeKind, profile: RuntimeExecutionProfile) throws {
        let matches: Bool
        switch (kind, profile) {
        case (.process, .directProcess), (.shell, .zshNoProfile), (.bash, .bashNoProfile),
             (.bash, .legacyBashLogin), (.python, .pythonIsolated),
             (.powershell, .powershellNoProfile):
            matches = true
        default:
            matches = false
        }
        guard matches else {
            throw RuntimeJobError.invalidRequest("runtime kind and execution profile do not match")
        }
    }

    private static func requiredScript(_ request: RuntimeJobRequest) throws -> String {
        guard let script = request.script, !script.isEmpty else {
            throw RuntimeJobError.invalidRequest("this runtime profile requires a script")
        }
        return script
    }

    private static func timeoutSeconds(_ duration: Duration, maximum: Int) throws -> Int {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw RuntimeJobError.invalidRequest("timeout must be positive")
        }
        let fractional = components.attoseconds > 0 ? 1 : 0
        guard components.seconds <= Int64(maximum) else {
            throw RuntimeJobError.invalidRequest("timeout exceeds the supported maximum")
        }
        let seconds = Int(components.seconds) + fractional
        guard seconds > 0, seconds <= maximum else {
            throw RuntimeJobError.invalidRequest("timeout must be between 1 and \(maximum) seconds")
        }
        return seconds
    }

    private static func authorizedWorkingDirectory(_ requested: URL, roots: [URL]) throws -> URL {
        var isDirectory: ObjCBool = false
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RuntimeJobError.invalidRequest("working directory does not exist")
        }
        let authorized = roots
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .contains { contains(canonical, root: $0) }
        guard authorized else {
            throw RuntimeJobError.workingDirectoryOutsideProject(canonical.path)
        }
        return canonical
    }

    private static func executableURL(_ requested: URL) throws -> URL {
        guard requested.path.hasPrefix("/"), !requested.path.contains("\0") else {
            throw RuntimeJobError.invalidRequest("direct process executable must be an absolute path")
        }
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: canonical.path) else {
            throw RuntimeJobError.executableUnavailable(canonical.path)
        }
        return canonical
    }

    private static func contains(_ child: URL, root: URL) -> Bool {
        let childPath = child.path
        let rootPath = root.path
        return childPath == rootPath || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func sanitizedEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SHELL", "USER", "LOGNAME", "TERM"]
        var result: [String: String] = [:]
        for key in allowed {
            guard let value = source[key], value.utf8.count <= 8 * 1_024, !value.contains("\0") else { continue }
            result[key] = value
        }
        if result["PATH"] == nil { result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return result
    }

    private static func isCPUHeavy(_ kind: RuntimeKind) -> Bool {
        kind == .python || kind == .powershell
    }
}

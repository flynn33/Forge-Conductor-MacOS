// DesktopProviderHookBridge.swift
// What: Connects authenticated desktop-provider hooks to the local manager.
// How: A loopback-only bounded client forwards validated envelopes, while one policy
// service produces host-compatible context or narrowly scoped Forge-tool denials.
// Why: Desktop hosts execute the model session; Forge supplies orchestration and MCP.

import Darwin
import Foundation

/// Owns the durable pull side of desktop-provider runs. Hook calls are short
/// control-plane transactions; potentially long native completion gates run in
/// one tracked task per run and are recovered after manager restart.
actor DesktopProviderRunLifecycleService {
    private static let maximumConcurrentCompletionTasks = 16
    private enum Metadata {
        static let sessionID = "desktop_plugin_session_id"
        static let providerID = "desktop_plugin_provider_id"
        static let sessionState = "desktop_plugin_session_state"
        static let lastEvent = "desktop_plugin_last_event"
        static let lastTool = "desktop_plugin_last_tool"
        static let completionSummary = "desktop_plugin_completion_summary"
    }

    private let repository: ProjectControlPlaneRepository
    private let completionValidator: any RunCompletionValidating
    private let clock: any Clock
    private let completionLeasePolicy = RunLeasePolicy(
        duration: 60,
        renewalInterval: 20,
        maximumDuration: 3_600
    )
    private var completionTasks: [RunID: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        repository: ProjectControlPlaneRepository,
        completionValidator: any RunCompletionValidating,
        clock: any Clock
    ) {
        self.repository = repository
        self.completionValidator = completionValidator
        self.clock = clock
    }

    func start() async throws {
        stopped = false
        try await recoverInterruptedSessions()
        try await reconcile()
    }

    /// A manager process cannot prove that a previously bound desktop session
    /// survived its outage. Release every persisted active desktop claim during
    /// startup so a SessionStart/UserPromptSubmit can reclaim the exact run.
    /// Ordinary reconciliation ticks intentionally do not call this method.
    private func recoverInterruptedSessions() async throws {
        let runs = try await repository.nonterminalAutonomousRuns(limit: 1_024)
        for run in runs where Self.isDesktopRun(run)
            && run.specification.work.metadata[Metadata.sessionState] == "active" {
            guard let sessionID = run.specification.work.metadata[Metadata.sessionID],
                  !sessionID.isEmpty else {
                throw ProjectContextError.integrityFailure(
                    "active desktop run is missing its bound session identity"
                )
            }
            var work = run.specification.work
            work.metadata[Metadata.sessionState] = "ended"
            work.metadata[Metadata.lastEvent] = "ManagerRestart"
            var recovering = run
            for intermediate in Self.restartRecoveryIntermediates(for: run.state) {
                recovering = try await transition(
                    recovering,
                    sessionID: sessionID,
                    to: intermediate,
                    event: "desktop_plugin_manager_restart_preparing_recovery",
                    summary: "Manager restart released an interrupted desktop preparation claim",
                    work: work
                )
            }
            guard recovering.state != .cancelRequested else { continue }
            _ = try await transition(
                recovering,
                sessionID: sessionID,
                to: .failedRecoverable,
                event: "desktop_plugin_manager_restart_recovery",
                summary: "Manager restart released the interrupted desktop session claim",
                work: work,
                errorCode: "desktop_plugin_manager_restarted",
                errorSummary: "Open the selected desktop provider in this project to resume the interrupted task."
            )
        }
    }

    func reconcile() async throws {
        let runs = try await repository.nonterminalAutonomousRuns(limit: 1_024)
        for run in runs where Self.isDesktopRun(run) {
            if run.state == .cancelRequested {
                _ = try? await finalizeCancellation(runID: run.runID)
            } else if run.state == .validatingCompletion {
                scheduleCompletion(runID: run.runID)
            }
        }
    }

    func shutdown() async {
        stopped = true
        let tasks = Array(completionTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        completionTasks.removeAll(keepingCapacity: false)
    }

    func hasRetainedWork() -> Bool { !completionTasks.isEmpty }

    func finalizeCancellation(runID: RunID) async throws -> AutonomousRunRecord {
        guard let run = try await repository.autonomousRun(runID) else {
            throw AutonomyError.runNotFound(runID)
        }
        guard Self.isDesktopRun(run), run.state == .cancelRequested else {
            throw AutonomyError.invalidRequest(
                "Desktop-host cancellation requires a cancel-requested desktop run"
            )
        }
        let lease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: "desktop-cancel:\(UUID().uuidString.lowercased())"
        )
        do {
            let cancelled = try await repository.transitionAutonomousRun(
                runID: runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: run.state,
                    expectedRevision: run.revision,
                    nextState: .cancelled,
                    eventType: "desktop_plugin_run_cancelled",
                    eventSummary: "Desktop-host run cancellation completed"
                )
            )
            _ = try await repository.releaseRunLease(lease)
            return cancelled
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
    }

    func handle(
        request: DesktopProviderHookRequest,
        selectionRevision: String
    ) async throws -> DesktopProviderRunHookDirective {
        guard !stopped,
              let sessionID = request.sessionID,
              let workingDirectory = request.workingDirectory,
              let canonicalWorkingDirectory = Self.canonicalDirectory(workingDirectory) else {
            return .none
        }

        let lookup = try await matchingRun(
            request: request,
            sessionID: sessionID,
            selectionRevision: selectionRevision,
            workingDirectory: canonicalWorkingDirectory,
            permitClaim: request.event == .sessionStart || request.event == .userPromptSubmit
        )
        guard var run = lookup.run else { return .none }

        if run.state == .cancelRequested {
            run = try await transition(
                run,
                sessionID: sessionID,
                to: .cancelled,
                event: "desktop_plugin_run_cancelled",
                summary: "Desktop-host run cancellation completed"
            )
            return .none
        }

        if lookup.requiresClaim {
            run = try await claim(run, request: request, sessionID: sessionID)
        }

        switch request.event {
        case .sessionStart, .userPromptSubmit:
            if run.state == .validatingCompletion {
                scheduleCompletion(runID: run.runID)
                return .context(
                    "Forge Conductor is running deterministic completion checks for run \(run.runID.description). Do not start unrelated work; continue only if Forge returns this run to running."
                )
            }
            guard run.state == .running,
                  let deploymentID = run.specification.work.metadata[
                    "provider_deployment_id"
                  ] else {
                throw ProjectContextError.integrityFailure(
                    "desktop provider attachment requires a live claimed deployment"
                )
            }
            let attachment = try await repository.issueDesktopProviderMCPAttachment(
                runID: run.runID,
                providerID: request.providerID,
                sessionID: sessionID,
                selectionRevision: selectionRevision,
                deploymentID: deploymentID
            )
            return .context(try Self.assignmentContext(run, attachment: attachment))
        case .preToolUse, .postToolUse, .postToolUseFailure:
            if run.state == .running {
                _ = try await recordActivity(run, request: request, sessionID: sessionID)
            }
            return .none
        case .stop:
            return try await handleStop(run, request: request, sessionID: sessionID)
        case .sessionEnd:
            if run.state == .running {
                var work = run.specification.work
                work.metadata[Metadata.sessionState] = "ended"
                work.metadata[Metadata.lastEvent] = request.event.rawValue
                _ = try await transition(
                    run,
                    sessionID: sessionID,
                    to: .failedRecoverable,
                    event: "desktop_plugin_session_ended",
                    summary: "Desktop host session ended before deterministic completion",
                    work: work,
                    errorCode: "desktop_plugin_session_ended",
                    errorSummary: "Open the selected desktop provider in this project to resume the task."
                )
            } else if run.state == .validatingCompletion {
                scheduleCompletion(runID: run.runID)
            }
            return .none
        case .permissionRequest:
            return .none
        }
    }

    private struct Match {
        let run: AutonomousRunRecord?
        let requiresClaim: Bool
    }

    private func matchingRun(
        request: DesktopProviderHookRequest,
        sessionID: String,
        selectionRevision: String,
        workingDirectory: URL,
        permitClaim: Bool
    ) async throws -> Match {
        let runs = try await repository.nonterminalAutonomousRuns(limit: 1_024).filter {
            Self.isDesktopRun($0)
                && $0.providerID == request.providerID.rawValue
                && $0.specification.work.metadata["provider_selection_revision"] == selectionRevision
        }
        var exact: [AutonomousRunRecord] = []
        var claimable: [(run: AutonomousRunRecord, rootPath: String, projectID: ProjectID)] = []
        var projects: [ProjectID: ProjectControlRecord] = [:]
        var missingProjects = Set<ProjectID>()
        for run in runs {
            let project: ProjectControlRecord?
            if let cached = projects[run.projectID] {
                project = cached
            } else if missingProjects.contains(run.projectID) {
                project = nil
            } else if let loaded = try await repository.project(run.projectID) {
                projects[run.projectID] = loaded
                project = loaded
            } else {
                missingProjects.insert(run.projectID)
                project = nil
            }
            guard let project,
                  project.lifecycleState == .active,
                  project.generation == run.projectGeneration,
                  Self.contains(workingDirectory, root: project.canonicalRoot) else {
                continue
            }
            let metadata = run.specification.work.metadata
            if metadata[Metadata.sessionID] == sessionID,
               metadata[Metadata.providerID] == request.providerID.rawValue,
               metadata[Metadata.sessionState] == "active" {
                exact.append(run)
                continue
            }
            guard permitClaim, Self.isClaimable(run, now: clock.now()) else { continue }
            claimable.append((
                run,
                project.canonicalRoot.resolvingSymlinksInPath().path,
                project.projectID
            ))
        }
        guard exact.count <= 1 else {
            throw ProjectContextError.integrityFailure(
                "desktop provider session is bound to multiple autonomous runs"
            )
        }
        if let existing = exact.first {
            return Match(
                run: existing,
                requiresClaim: permitClaim && Self.requiresRecoveryClaim(existing)
            )
        }
        guard let maximumSpecificity = claimable.map({ $0.rootPath.utf8.count }).max() else {
            return Match(run: nil, requiresClaim: false)
        }
        let mostSpecific = claimable.filter { $0.rootPath.utf8.count == maximumSpecificity }
        guard mostSpecific.count == 1 else {
            throw ProjectContextError.integrityFailure(
                "desktop provider working directory matches multiple autonomous runs"
            )
        }
        return Match(run: mostSpecific.first?.run, requiresClaim: true)
    }

    private func claim(
        _ initial: AutonomousRunRecord,
        request: DesktopProviderHookRequest,
        sessionID: String
    ) async throws -> AutonomousRunRecord {
        var run = initial
        var work = run.specification.work
        work.metadata[Metadata.sessionID] = sessionID
        work.metadata[Metadata.providerID] = request.providerID.rawValue
        work.metadata[Metadata.sessionState] = "active"
        work.metadata[Metadata.lastEvent] = request.event.rawValue
        let lease = try await repository.acquireRunLease(
            runID: run.runID,
            ownerID: Self.leaseOwner(providerID: request.providerID, sessionID: sessionID)
        )
        do {
            for _ in 0..<6 {
                let next: AutonomousRunState?
                switch run.state {
                case .created: next = .validating
                case .validating: next = .ready
                case .ready: next = .starting
                case .starting, .recovering: next = .running
                case .waitingProvider, .waitingResource, .retryWait, .failedRecoverable:
                    next = .recovering
                case .running:
                    if run.specification.work.metadata[Metadata.sessionID] == sessionID {
                        next = nil
                    } else {
                        run = try await repository.transitionAutonomousRun(
                            runID: run.runID,
                            lease: lease,
                            transition: AutonomousRunTransition(
                                expectedState: run.state,
                                expectedRevision: run.revision,
                                nextState: .running,
                                eventType: "desktop_plugin_run_claimed",
                                eventSummary: "Desktop host claimed the project-scoped run",
                                work: work,
                                activeSessionID: sessionID
                            )
                        )
                        next = nil
                    }
                default: next = nil
                }
                guard let next else { break }
                run = try await repository.transitionAutonomousRun(
                    runID: run.runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: next,
                        eventType: next == .running
                            ? "desktop_plugin_run_claimed" : "desktop_plugin_run_prepared",
                        eventSummary: next == .running
                            ? "Desktop host claimed the project-scoped run"
                            : "Desktop-host run advanced through durable preparation",
                        work: work,
                        activeSessionID: sessionID
                    )
                )
            }
            guard run.state == .running else {
                throw AutonomyError.invalidRequest(
                    "Desktop-host run is not in a claimable execution state"
                )
            }
            _ = try await repository.releaseRunLease(lease)
            return run
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
    }

    private func recordActivity(
        _ run: AutonomousRunRecord,
        request: DesktopProviderHookRequest,
        sessionID: String
    ) async throws -> AutonomousRunRecord {
        var work = run.specification.work
        work.metadata[Metadata.lastEvent] = request.event.rawValue
        if let toolName = request.toolName { work.metadata[Metadata.lastTool] = toolName }
        // Tool boundaries are high-frequency operator projections. Keeping them
        // in the managed tool family applies the repository's per-run rolling
        // cap without pruning sparse claim, recovery, or completion audit events.
        let event: String
        let summary: String
        switch request.event {
        case .preToolUse:
            event = "managed_activity_tool_desktop_executing"
            summary = "Desktop host started a tool boundary"
        case .postToolUse:
            event = "managed_activity_tool_desktop_completed"
            summary = "Desktop host completed a tool boundary"
        case .postToolUseFailure:
            event = "managed_activity_tool_desktop_failed"
            summary = "Desktop host reported a failed tool boundary"
        default:
            throw AutonomyError.invalidRequest(
                "Desktop activity recording requires a tool-boundary hook event"
            )
        }
        return try await transition(
            run,
            sessionID: sessionID,
            to: .running,
            event: event,
            summary: summary,
            work: work
        )
    }

    private func handleStop(
        _ run: AutonomousRunRecord,
        request: DesktopProviderHookRequest,
        sessionID: String
    ) async throws -> DesktopProviderRunHookDirective {
        if run.state == .completed || run.state == .cancelled || run.state == .failedTerminal {
            return .none
        }
        if run.state == .validatingCompletion {
            scheduleCompletion(runID: run.runID)
            return .continueRun("Forge Conductor is running the task's deterministic completion checks. Keep this turn active and check the run again.")
        }
        if run.state == .blockedConfiguration || run.state == .paused {
            return .none
        }
        guard run.state == .running else {
            return .continueRun("Forge Conductor is recovering this run. Continue only after its durable state returns to running.")
        }
        guard let completion = request.completionRequest() else {
            return .continueRun(Self.continuationReason(run))
        }
        guard completion.runID == run.runID else {
            return .continueRun(
                "The completion marker named a different run. Continue run \(run.runID.description) and use its exact run_id in the final marker."
            )
        }
        var work = run.specification.work
        work.metadata[Metadata.lastEvent] = request.event.rawValue
        work.metadata[Metadata.completionSummary] = completion.summary
        let requestJSON = try JSONSupport.canonicalJSON(["request": completion.summary])
        let validating = try await transition(
            run,
            sessionID: sessionID,
            to: .validatingCompletion,
            event: "desktop_plugin_completion_requested",
            summary: "Desktop host requested deterministic completion validation",
            work: work,
            completionRequestJSON: requestJSON
        )
        scheduleCompletion(runID: validating.runID)
        return .continueRun(
            "Forge Conductor accepted the completion request for run \(run.runID.description) and is running its native completion checks. Keep this turn active until validation settles."
        )
    }

    private func scheduleCompletion(runID: RunID) {
        guard !stopped,
              completionTasks[runID] == nil,
              completionTasks.count < Self.maximumConcurrentCompletionTasks else { return }
        completionTasks[runID] = Task { [weak self] in
            guard let self else { return }
            await self.performCompletionValidation(runID: runID)
            await self.completionTaskFinished(runID: runID)
        }
    }

    private func completionTaskFinished(runID: RunID) {
        completionTasks.removeValue(forKey: runID)
    }

    private func performCompletionValidation(runID: RunID) async {
        var lease: RunLease?
        do {
            var acquired: RunLease?
            for attempt in 0..<7 {
                do {
                    acquired = try await repository.acquireRunLease(
                        runID: runID,
                        ownerID: "desktop-completion:\(UUID().uuidString.lowercased())",
                        policy: completionLeasePolicy
                    )
                    break
                } catch let error as AutonomyError {
                    guard case .leaseConflict = error, attempt < 6 else { throw error }
                    try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                }
            }
            guard var currentLease = acquired else { return }
            lease = currentLease
            guard let run = try await repository.autonomousRun(runID),
                  run.state == .validatingCompletion,
                  Self.isDesktopRun(run) else {
                _ = try await repository.releaseRunLease(currentLease)
                return
            }
            let protected = try await RunLeaseProtection.withRenewal(
                currentLease,
                repository: repository,
                policy: completionLeasePolicy,
                sleeper: SystemAutonomySleeper()
            ) { [completionValidator] in
                try await completionValidator.validate(run)
            }
            currentLease = protected.lease
            lease = currentLease
            let receipt = protected.value
            if receipt.passed {
                try await repository.recordTrustedCompletionValidation(
                    receipt,
                    for: run,
                    lease: currentLease
                )
                _ = try await repository.completeAutonomousRun(
                    runID: runID,
                    lease: currentLease,
                    receipt: receipt
                )
            } else {
                var work = run.specification.work
                work.pendingIntent = nil
                work.metadata["completion_proof_sha256"] = receipt.proofSHA256
                let summary = ProjectRunCoordinator.completionFailureSummary(receipt)
                work.nextAction = summary
                _ = try await repository.transitionAutonomousRun(
                    runID: runID,
                    lease: currentLease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: receipt.results.contains(where: { $0.blocker != nil })
                            ? .blockedConfiguration : .running,
                        eventType: "desktop_plugin_completion_rejected",
                        eventSummary: summary,
                        work: work,
                        errorCode: AutonomyError.completionValidationFailed.code,
                        errorSummary: summary
                    )
                )
            }
            _ = try await repository.releaseRunLease(currentLease)
        } catch is CancellationError {
            if let lease { _ = try? await repository.releaseRunLease(lease) }
        } catch {
            if let lease {
                do {
                    if let run = try await repository.autonomousRun(runID),
                       run.state == .validatingCompletion {
                        var work = run.specification.work
                        let detail = Self.bounded(error.localizedDescription, maximumBytes: 1_600)
                        work.nextAction = "Retry deterministic completion validation after correcting: \(detail)"
                        _ = try await repository.transitionAutonomousRun(
                            runID: runID,
                            lease: lease,
                            transition: AutonomousRunTransition(
                                expectedState: run.state,
                                expectedRevision: run.revision,
                                nextState: .failedRecoverable,
                                eventType: "desktop_plugin_completion_failed_recoverable",
                                eventSummary: "Desktop completion validation failed and can be retried",
                                work: work,
                                errorCode: "desktop_completion_validation_failed",
                                errorSummary: detail
                            )
                        )
                    }
                } catch {
                    // A stale/expired lease leaves the durable validation request
                    // intact for the next hook or manager-start recovery scan.
                }
                _ = try? await repository.releaseRunLease(lease)
            }
        }
    }

    private func transition(
        _ run: AutonomousRunRecord,
        sessionID: String,
        to state: AutonomousRunState,
        event: String,
        summary: String,
        work: AutonomousRunWork? = nil,
        completionRequestJSON: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil
    ) async throws -> AutonomousRunRecord {
        let lease = try await repository.acquireRunLease(
            runID: run.runID,
            ownerID: Self.leaseOwner(
                providerID: ProviderIntegrationID(rawValue: run.providerID ?? "") ?? .codexDesktop,
                sessionID: sessionID
            )
        )
        do {
            let updated = try await repository.transitionAutonomousRun(
                runID: run.runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: run.state,
                    expectedRevision: run.revision,
                    nextState: state,
                    eventType: event,
                    eventSummary: summary,
                    work: work,
                    activeSessionID: sessionID,
                    completionRequestJSON: completionRequestJSON,
                    errorCode: errorCode,
                    errorSummary: errorSummary
                )
            )
            _ = try await repository.releaseRunLease(lease)
            return updated
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
    }

    private static func isDesktopRun(_ run: AutonomousRunRecord) -> Bool {
        run.specification.work.metadata["execution_strategy"]
            == ProviderExecutionStrategy.desktopPluginPull.rawValue
    }

    private static func isClaimable(_ run: AutonomousRunRecord, now: Date) -> Bool {
        let sessionActive = run.specification.work.metadata[Metadata.sessionState] == "active"
        if sessionActive { return false }
        switch run.state {
        case .created, .validating, .ready, .starting, .recovering, .failedRecoverable:
            return true
        case .waitingProvider, .waitingResource, .retryWait:
            guard let retryAt = run.retryAt,
                  let deadline = ISO8601.date(from: retryAt) else {
                return false
            }
            return deadline <= now
        case .running:
            return run.activeSessionID == nil
                || run.specification.work.metadata[Metadata.sessionState] == "ended"
        default:
            return false
        }
    }

    private static func restartRecoveryIntermediates(
        for state: AutonomousRunState
    ) -> [AutonomousRunState] {
        switch state {
        case .created:
            [.validating]
        case .ready:
            [.starting]
        case .checkpointing, .rollingOver, .waitingProvider, .waitingResource,
             .retryWait, .paused, .blockedConfiguration, .failedRecoverable:
            [.recovering]
        case .validating, .starting, .running, .recovering, .validatingCompletion:
            []
        case .awaitingBootstrap:
            [.cancelRequested]
        case .cancelRequested:
            []
        case .completed, .cancelled, .failedTerminal:
            []
        }
    }

    private static func requiresRecoveryClaim(_ run: AutonomousRunRecord) -> Bool {
        switch run.state {
        case .validating, .ready, .starting, .recovering,
             .waitingProvider, .waitingResource, .retryWait, .failedRecoverable:
            return true
        default:
            return false
        }
    }

    private static func canonicalDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func leaseOwner(
        providerID: ProviderIntegrationID,
        sessionID: String
    ) -> String {
        "desktop-hook:\(providerID.rawValue):\(JSONSupport.sha256Hex(sessionID).prefix(32))"
    }

    static func validateAssignmentContext(_ request: AutonomousRunRequest) throws {
        var requiredLines = try requiredAssignmentLines(
            runID: request.runID,
            completionGates: request.specification.completionGates,
            mission: request.mission,
            allowedTools: request.specification.allowedTools,
            metadata: request.specification.work.metadata
        )
        requiredLines.append(try attachmentDirective(attachmentPreview(for: request)))
        let required = requiredLines.joined(separator: "\n")
        guard required.utf8.count <= DesktopProviderHookContract.maximumAssignmentContextBytes else {
            throw AutonomyError.invalidRequest(
                "Desktop-provider instructions exceed the exact assignment context limit; shorten the mission or completion-check names"
            )
        }
    }

    private static func assignmentContext(
        _ run: AutonomousRunRecord,
        attachment: DesktopProviderMCPAttachmentCapability
    ) throws -> String {
        guard attachment.runID == run.runID,
              attachment.projectID == run.projectID,
              attachment.projectGeneration == run.projectGeneration,
              attachment.providerID.rawValue == run.providerID else {
            throw ProjectContextError.integrityFailure(
                "desktop provider attachment does not match its autonomous run"
            )
        }
        var lines = try requiredAssignmentLines(
            runID: run.runID,
            completionGates: run.specification.completionGates,
            mission: run.mission,
            allowedTools: run.specification.allowedTools,
            metadata: run.specification.work.metadata
        )
        lines.append(try attachmentDirective(attachment))
        guard lines.joined(separator: "\n").utf8.count
                <= DesktopProviderHookContract.maximumAssignmentContextBytes else {
            throw ProjectContextError.integrityFailure(
                "desktop provider assignment cannot deliver its full mission"
            )
        }
        let optionalLines = [
            "Durable state: \(run.state.rawValue)",
            run.specification.work.currentPhase.map { "Current phase: \($0)" },
            run.specification.work.workItem.map { "Work item: \($0)" },
            run.specification.work.nextAction.map { "Next action: \($0)" },
            run.lastErrorSummary.map { "Needs attention: \($0)" },
        ].compactMap { $0 }
        for line in optionalLines {
            let candidate = (lines + [line]).joined(separator: "\n")
            if candidate.utf8.count <= DesktopProviderHookContract.maximumAssignmentContextBytes {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func attachmentPreview(
        for request: AutonomousRunRequest
    ) throws -> DesktopProviderMCPAttachmentCapability {
        guard let providerID = ProviderIntegrationID(rawValue: request.providerID),
              DesktopProviderMCPAttachmentRequest.isSelectableDesktopProvider(providerID),
              let selectionRevision = request.specification.work.metadata[
                "provider_selection_revision"
              ],
              let deploymentID = request.specification.work.metadata[
                "provider_deployment_id"
              ] else {
            throw AutonomyError.invalidRequest(
                "Desktop-provider assignments require an exact selected deployment identity"
            )
        }
        return DesktopProviderMCPAttachmentCapability(
            token: String(repeating: "0", count: 64),
            providerID: providerID,
            runID: request.runID,
            projectID: request.projectID,
            projectGeneration: request.projectGeneration,
            sessionSHA256: String(repeating: "0", count: 64),
            selectionRevision: selectionRevision,
            deploymentID: deploymentID,
            expiresAt: "2000-01-01T00:00:00Z"
        )
    }

    private static func attachmentDirective(
        _ capability: DesktopProviderMCPAttachmentCapability
    ) throws -> String {
        let arguments = try JSONSupport.string(from: capability.toolArguments)
        return "Before any other Forge MCP tool, call desktop_run_attach exactly once with this exact argument object: \(arguments). This single-use attachment expires at \(capability.expiresAt); if it is rejected, request a fresh Forge assignment context instead of changing any identity field."
    }

    private static func requiredAssignmentLines(
        runID: RunID,
        completionGates: [String],
        mission: String,
        allowedTools: [String],
        metadata: [String: String]
    ) throws -> [String] {
        var lines = [
            "Forge Conductor assigned autonomous run \(runID.description).",
            "Work only on this run and its project scope. Never claim another project or bypass a permission prompt.",
            "Before stopping after the work is genuinely ready, end the assistant message with exactly {\"forge_run_status\":\"completion_requested\",\"run_id\":\"\(runID.description)\",\"summary\":\"bounded factual summary\"}. Forge independently runs the registered completion checks.",
        ]
        let sourceKind = metadata["source_kind"]
        let usesArtifact = sourceKind == ManagerPreparedRunSourceKind.instructionArtifact.rawValue
            || sourceKind == ManagerPreparedRunSourceKind.instructionPackage.rawValue
            || metadata["instruction_package_sha256"] != nil
        if usesArtifact {
            guard let digest = metadata["source_snapshot_sha256"],
                  digest.utf8.count == 64,
                  digest.unicodeScalars.allSatisfy({
                      (48...57).contains($0.value) || (97...102).contains($0.value)
                  }),
                  Set(["instruction_catalog", "instruction_read"]).isSubset(of: Set(allowedTools)) else {
                throw AutonomyError.invalidRequest(
                    "Desktop-provider artifact assignments require an exact snapshot digest and instruction_catalog/instruction_read access"
                )
            }
            lines.append("Instruction source: immutable project-scoped artifact snapshot \(digest).")
            lines.append("Before modifying the project, call instruction_catalog for this run and read every listed instruction document with instruction_read. Treat the artifact as the complete authoritative mission.")
        } else {
            lines.append("Mission: \(mission)")
        }
        lines.append("Completion checks: \(completionGates.joined(separator: ", "))")
        return lines
    }

    private static func continuationReason(_ run: AutonomousRunRecord) -> String {
        let action = run.specification.work.nextAction.map { " Next action: \($0)" } ?? ""
        return bounded(
            "Forge Conductor run \(run.runID.description) is still active and has not requested deterministic completion. Continue the mission.\(action) When ready, emit the exact run-bound completion marker supplied in the assignment context.",
            maximumBytes: 2_048
        )
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            guard count + width <= maximumBytes else { break }
            result.append(character)
            count += width
        }
        return result
    }
}

public struct DesktopProviderHookPolicyService: Sendable {
    public init() {}

    public func response(
        snapshot: ProviderIntegrationsSnapshot,
        request: DesktopProviderHookRequest,
        runDirective: DesktopProviderRunHookDirective = .none
    ) -> DesktopProviderHookResponse {
        let selected = snapshot.selectedProviderID == request.providerID
        switch request.event {
        case .sessionStart, .userPromptSubmit:
            let runContext = if case .context(let context) = runDirective {
                "\n\n" + context
            } else {
                ""
            }
            return contextResponse(
                event: request.event,
                context: selected
                    ? activeContext(providerID: request.providerID) + runContext
                    : inactiveContext(providerID: request.providerID)
            )
        case .stop where selected:
            if case .continueRun(let reason) = runDirective {
                return Self.stopContinuationResponse(reason: reason)
            }
            return .empty
        case .preToolUse where !selected && Self.isForgeMCPTool(
            request.toolName,
            providerID: request.providerID
        ):
            return Self.deniedResponse(
                reason: "Forge Conductor denied this Forge MCP call because this desktop provider is not the active provider."
            )
        case .preToolUse, .permissionRequest, .postToolUse, .postToolUseFailure,
             .stop, .sessionEnd:
            // An empty response preserves the host's own permission decision. In
            // particular, Forge never emits an automatic allow decision.
            return .empty
        }
    }

    public static func failureFallback(
        for request: DesktopProviderHookRequest
    ) -> DesktopProviderHookResponse {
        guard request.event == .preToolUse,
              isForgeMCPTool(request.toolName, providerID: request.providerID) else {
            return .empty
        }
        return deniedResponse(
            reason: "Forge Conductor denied this Forge MCP call because its local orchestration policy is unavailable."
        )
    }

    public static func isForgeMCPTool(
        _ toolName: String?,
        providerID: ProviderIntegrationID
    ) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        if toolName == "forge_status" { return true }
        switch providerID {
        case .claudeDesktop, .codexDesktop:
            return toolName.hasPrefix("mcp__forge-conductor__")
                || toolName.hasPrefix("mcp__forge_conductor__")
                || toolName.hasPrefix(
                    "mcp__plugin_forge-conductor_forge-conductor__"
                )
        case .grokBuild:
            return toolName.hasPrefix("forge-conductor__")
        case .lmStudio:
            return false
        }
    }

    private func contextResponse(
        event: DesktopProviderHookEvent,
        context: String
    ) -> DesktopProviderHookResponse {
        DesktopProviderHookResponse(object: [
            "hookSpecificOutput": .object([
                "hookEventName": .string(event.rawValue),
                "additionalContext": .string(context),
            ]),
        ])
    }

    private func activeContext(providerID: ProviderIntegrationID) -> String {
        "Forge Conductor is the orchestration and MCP layer for this session. \(displayName(providerID)) executes the model session; Forge is not a direct model API for this provider. Use the configured Forge MCP server for project-scoped tools, memory, and continuity."
    }

    private func inactiveContext(providerID: ProviderIntegrationID) -> String {
        "The Forge Conductor integration for \(displayName(providerID)) is inactive. Another provider is selected, so Forge MCP tools must not be used from this session until this provider is activated in Forge Conductor."
    }

    private func displayName(_ providerID: ProviderIntegrationID) -> String {
        ProviderIntegrationDescriptor.supported.first(where: { $0.id == providerID })?
            .displayName ?? providerID.rawValue
    }

    private static func deniedResponse(reason: String) -> DesktopProviderHookResponse {
        DesktopProviderHookResponse(object: [
            "hookSpecificOutput": .object([
                "hookEventName": .string(DesktopProviderHookEvent.preToolUse.rawValue),
                "permissionDecision": .string("deny"),
                "permissionDecisionReason": .string(reason),
            ]),
        ])
    }

    private static func stopContinuationResponse(reason: String) -> DesktopProviderHookResponse {
        DesktopProviderHookResponse(object: [
            "decision": .string("block"),
            "reason": .string(reason),
        ])
    }
}

public final class DesktopProviderHookBridge: @unchecked Sendable {
    private let paths: AppPaths
    private let sessionConfiguration: URLSessionConfiguration
    private let credentials: any ManagerMutationCredentialProviding

    public init(
        paths: AppPaths,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        credentials: (any ManagerMutationCredentialProviding)? = nil
    ) {
        self.paths = paths
        self.sessionConfiguration = sessionConfiguration
        self.credentials = credentials ?? ManagerControlCredentialStore(paths: paths)
    }

    /// Returns a host-safe response for every already-validated request. Manager
    /// failures deny only Forge MCP PreToolUse calls and leave unrelated host use intact.
    public func forward(_ request: DesktopProviderHookRequest) async -> Data {
        do {
            return try await send(request)
        } catch {
            return (try? DesktopProviderHookPolicyService.failureFallback(for: request).encodedData())
                ?? Data("{}".utf8)
        }
    }

    /// Throwing transport entry retained for focused boundary tests and manager clients.
    public func send(_ request: DesktopProviderHookRequest) async throws -> Data {
        let endpoint = try Self.endpoint(paths: paths)
        let body = try request.envelopeData()
        let token = try credentials.bearerToken()

        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = DesktopProviderHookContract.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = DesktopProviderHookContract.requestTimeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: DesktopProviderHookContract.requestTimeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let redirectGuard = DesktopProviderHookRedirectGuard()
        let (bytes, response) = try await session.bytes(
            for: urlRequest,
            delegate: redirectGuard
        )
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              http.url == endpoint,
              http.statusCode == 200 else {
            throw DesktopProviderHookError.managerUnavailable
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0
                || expectedLength <= Int64(DesktopProviderHookContract.maximumResponseBytes) else {
            throw DesktopProviderHookError.responseTooLarge
        }
        var responseData = Data()
        responseData.reserveCapacity(
            expectedLength > 0
                ? min(Int(expectedLength), DesktopProviderHookContract.maximumResponseBytes)
                : 1_024
        )
        for try await byte in bytes {
            guard responseData.count < DesktopProviderHookContract.maximumResponseBytes else {
                throw DesktopProviderHookError.responseTooLarge
            }
            responseData.append(byte)
        }
        _ = try DesktopProviderHookResponse(data: responseData)
        // Preserve the manager's exact validated JSON bytes. No credential or
        // filesystem diagnostics are ever mixed into the host's stdout channel.
        return responseData
    }

    static func endpoint(paths: AppPaths) throws -> URL {
        let dashboard = ConfigStore(paths: paths).model.dashboard
        guard (1...65_535).contains(dashboard.port) else {
            throw DesktopProviderHookError.invalidEndpoint
        }
        let configured = dashboard.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = try normalizedLoopbackHost(configured)
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = dashboard.port
        components.path = "/api/manager/providers/hooks"
        guard let endpoint = components.url,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw DesktopProviderHookError.invalidEndpoint
        }
        return endpoint
    }

    private static func normalizedLoopbackHost(_ configuredHost: String) throws -> String {
        let unbracketed: String
        if configuredHost.hasPrefix("["), configuredHost.hasSuffix("]") {
            unbracketed = String(configuredHost.dropFirst().dropLast())
        } else {
            unbracketed = configuredHost
        }
        let host = unbracketed.lowercased()
        if host == "0.0.0.0" { return "127.0.0.1" }
        if host == "::" { return "::1" }
        // Avoid relying on mutable hostname resolution for a credential-bearing
        // request even when the configured spelling is `localhost`.
        if host == "localhost" { return "127.0.0.1" }
        if host == "::1" { return host }

        var ipv4 = in_addr()
        let parsed = host.withCString { inet_pton(AF_INET, $0, &ipv4) }
        if parsed == 1 {
            let isLoopback = withUnsafeBytes(of: &ipv4) { bytes in
                bytes.first == 127
            }
            if isLoopback { return host }
        }
        throw DesktopProviderHookError.invalidEndpoint
    }
}

final class DesktopProviderHookRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct DesktopProviderHookInvocation: Sendable, Equatable {
    public let providerID: ProviderIntegrationID
    public let event: DesktopProviderHookEvent
    public let home: URL

    public static func parse(arguments: [String]) throws -> DesktopProviderHookInvocation {
        guard arguments.count == 4,
              let providerID = ProviderIntegrationID(rawValue: arguments[0]),
              DesktopProviderHookRequest.isDesktopProvider(providerID),
              let event = DesktopProviderHookEvent(rawValue: arguments[1]),
              arguments[2] == "--home" else {
            throw DesktopProviderHookError.invalidArguments
        }
        let expanded = (arguments[3] as NSString).expandingTildeInPath
        guard !expanded.isEmpty,
              expanded.utf8.count <= DesktopProviderHookContract.maximumHomePathBytes,
              (expanded as NSString).isAbsolutePath,
              !expanded.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DesktopProviderHookError.invalidArguments
        }
        return DesktopProviderHookInvocation(
            providerID: providerID,
            event: event,
            home: URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        )
    }
}

public enum DesktopProviderHookCommand {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func store(_ data: Data) {
            lock.lock(); self.data = data; lock.unlock()
        }

        func take() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    public static func run(
        arguments: [String],
        standardInput: FileHandle = .standardInput,
        standardOutput: FileHandle = .standardOutput
    ) throws {
        let invocation = try DesktopProviderHookInvocation.parse(arguments: arguments)
        let payload = try readBoundedInput(standardInput)
        let request = try DesktopProviderHookRequest(
            providerID: invocation.providerID,
            event: invocation.event,
            hostPayload: payload
        )
        let bridge = DesktopProviderHookBridge(paths: AppPaths(home: invocation.home))
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            box.store(await bridge.forward(request))
            semaphore.signal()
        }
        let waitResult = semaphore.wait(
            timeout: .now() + DesktopProviderHookContract.requestTimeoutSeconds + 1
        )
        let response: Data
        if waitResult == .success, let forwarded = box.take() {
            response = forwarded
        } else {
            task.cancel()
            response = try DesktopProviderHookPolicyService.failureFallback(for: request).encodedData()
        }
        try standardOutput.write(contentsOf: response)
    }

    static func readBoundedInput(_ handle: FileHandle) throws -> Data {
        var input = Data()
        while true {
            let remaining = DesktopProviderHookContract.maximumInputBytes - input.count
            guard remaining >= 0 else { throw DesktopProviderHookError.inputTooLarge }
            let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= remaining else {
                throw DesktopProviderHookError.inputTooLarge
            }
            input.append(chunk)
        }
        guard !input.isEmpty else { throw DesktopProviderHookError.invalidJSON }
        return input
    }
}

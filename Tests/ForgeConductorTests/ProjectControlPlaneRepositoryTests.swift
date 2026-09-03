// ProjectControlPlaneRepositoryTests.swift
// Verifies durable project isolation, exact owner binding, and generation fencing.

import XCTest
import Darwin
import SQLite3
@testable import ForgeConductorCore

final class ProjectControlPlaneRepositoryTests: XCTestCase {
    func testLockedRegistrationHonorsCancellationAndDeadlineWithoutPartialWrite() async throws {
        try await withRepository(busyTimeoutMilliseconds: 3_000) { repository, root in
            let writeLock = try ControlPlaneWriteLock(
                databaseURL: root.appendingPathComponent("control-plane.sqlite3")
            )
            let cancelledProjectID = ProjectID()
            let cancelled = ToolCallCancellation()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(50)
            ) {
                cancelled.cancel()
            }

            let cancellationStartedAt = Date()
            do {
                _ = try await repository.registerProjectUnchecked(
                    projectID: cancelledProjectID,
                    displayName: "Cancelled Project",
                    canonicalRoot: root.appendingPathComponent("cancelled-project", isDirectory: true),
                    cancellation: cancelled
                )
                XCTFail("Expected registration cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(cancellationStartedAt),
                2,
                "registration cancellation waited for the SQLite busy fallback"
            )

            let deadlineProjectID = ProjectID()
            let deadline = ToolCallCancellation(timeoutSeconds: 0.05)
            let deadlineStartedAt = Date()
            do {
                _ = try await repository.registerProjectUnchecked(
                    projectID: deadlineProjectID,
                    displayName: "Deadline Project",
                    canonicalRoot: root.appendingPathComponent("deadline-project", isDirectory: true),
                    cancellation: deadline
                )
                XCTFail("Expected registration deadline")
            } catch {
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(deadlineStartedAt),
                2,
                "registration deadline waited for the SQLite busy fallback"
            )

            writeLock.release()
            let cancelledProject = try await repository.project(cancelledProjectID)
            let deadlineProject = try await repository.project(deadlineProjectID)
            XCTAssertNil(cancelledProject)
            XCTAssertNil(deadlineProject)
        }
    }

    func testRegistrationChecksCancellationBeforeCommitAndReturnsCommittedResult() async throws {
        try await withRepository { repository, root in
            let precommitProjectID = ProjectID()
            let precommitCancellation = ToolCallCancellation()
            await repository.configureOperationObservers(beforeCommit: {
                precommitCancellation.cancel()
            })
            do {
                _ = try await repository.registerProjectUnchecked(
                    projectID: precommitProjectID,
                    displayName: "Precommit Project",
                    canonicalRoot: root.appendingPathComponent("precommit-project", isDirectory: true),
                    cancellation: precommitCancellation
                )
                XCTFail("Expected precommit cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }
            await repository.configureOperationObservers()
            let precommitProject = try await repository.project(precommitProjectID)
            XCTAssertNil(precommitProject)

            let committedProjectID = ProjectID()
            let postcommitCancellation = ToolCallCancellation()
            await repository.configureOperationObservers(didCommit: {
                postcommitCancellation.cancel()
            })
            let committed = try await repository.registerProjectUnchecked(
                projectID: committedProjectID,
                displayName: "Committed Project",
                canonicalRoot: root.appendingPathComponent("committed-project", isDirectory: true),
                cancellation: postcommitCancellation
            )
            await repository.configureOperationObservers()

            XCTAssertTrue(postcommitCancellation.isCancelled)
            XCTAssertEqual(committed.projectID, committedProjectID)
            let storedProject = try await repository.project(committedProjectID)
            XCTAssertEqual(storedProject, committed)
        }
    }

    func testProjectContextServicePropagatesDeadlineIntoLockedRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-project-context-service-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let service = try ProjectContextService(
            databaseURL: databaseURL,
            waitTimeout: .milliseconds(100),
            cancellationCleanupTimeout: .seconds(2)
        )
        defer {
            service.close()
            try? FileManager.default.removeItem(at: root)
        }
        let writeLock = try ControlPlaneWriteLock(databaseURL: databaseURL)
        let projectID = UUID().uuidString.lowercased()
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        let startedAt = Date()

        XCTAssertThrowsError(
            try service.registerProjectUnchecked(
                descriptor: ProjectMemoryDescriptor(
                    id: projectID,
                    displayName: "Service Deadline Project",
                    repositoryIdentity: nil,
                    aliases: []
                ),
                canonicalRoot: root.appendingPathComponent("service-project", isDirectory: true),
                cancellation: cancellation
            )
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2,
            "service bridge did not stop the locked repository at the request deadline"
        )

        let compatibilityProjectID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(
            try service.registerProjectUnchecked(
                descriptor: ProjectMemoryDescriptor(
                    id: compatibilityProjectID,
                    displayName: "Compatibility Timeout Project",
                    repositoryIdentity: nil,
                    aliases: []
                ),
                canonicalRoot: root.appendingPathComponent("compatibility-project", isDirectory: true)
            )
        ) { error in
            XCTAssertEqual((error as? ProjectContextError)?.code, "database_busy")
        }

        writeLock.release()
        XCTAssertNil(try service.project(ProjectID(UUID(uuidString: projectID)!)))
        XCTAssertNil(try service.project(ProjectID(UUID(uuidString: compatibilityProjectID)!)))
    }

    func testProjectContextBridgeCancelsMutationWithinBoundedCleanup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-project-context-truthful-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let service = try ProjectContextService(
            databaseURL: databaseURL,
            waitTimeout: .milliseconds(50),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        defer {
            service.close()
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID()
        _ = try service.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: projectID.description,
                displayName: "Truthful Mutation Project",
                repositoryIdentity: nil,
                aliases: [projectRoot.path]
            ),
            canonicalRoot: projectRoot
        )
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "truthful-mutation-client")
        _ = try service.bind(
            owner: owner,
            projectID: projectID,
            generation: .initial,
            authorizationScope: scope(root: projectRoot)
        )
        let context = try service.invocationContext(
            for: owner,
            clientID: ClientID(owner.id)
        )
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        let startedAt = Date()

        XCTAssertThrowsError(
            try service.commitIfCurrent(
                context: context,
                resultKind: "bounded-fixture-mutation",
                cancellation: cancellation
            ) { control in
                while true {
                    try control.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.005)
                }
            } as String
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertTrue(cancellation.isDeadlineExceeded)
    }

    func testProjectContextBridgeRevokesLateCommitFromUncooperativeMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-project-context-commit-fence-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let service = try ProjectContextService(
            databaseURL: databaseURL,
            waitTimeout: .milliseconds(50),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        defer {
            service.close()
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID()
        _ = try service.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: projectID.description,
                displayName: "Commit Fence Project",
                repositoryIdentity: nil,
                aliases: [projectRoot.path]
            ),
            canonicalRoot: projectRoot
        )
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "commit-fence-client")
        _ = try service.bind(
            owner: owner,
            projectID: projectID,
            generation: .initial,
            authorizationScope: scope(root: projectRoot)
        )
        let context = try service.invocationContext(for: owner, clientID: ClientID(owner.id))
        let mutationStarted = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let probe = MutationProbe()

        XCTAssertThrowsError(
            try service.commitIfCurrent(
                context: context,
                resultKind: "uncooperative-bounded-mutation"
            ) { control in
                mutationStarted.signal()
                _ = releaseMutation.wait(timeout: .now() + 1)
                defer { mutationFinished.signal() }
                return try control.withCommitAuthorization {
                    probe.increment()
                    return "late-commit"
                }
            } as String
        )
        XCTAssertEqual(mutationStarted.wait(timeout: .now()), .success)
        XCTAssertEqual(probe.value, 0)

        releaseMutation.signal()
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            probe.value,
            0,
            "a mutation released after the bridge returned crossed its revoked commit fence"
        )
    }

    func testProjectContextBridgeReturnsCommittedReceiptWhileRepositoryResultIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-project-context-post-commit-receipt-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let service = try ProjectContextService(
            databaseURL: databaseURL,
            waitTimeout: .milliseconds(50),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        defer {
            service.close()
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID()
        _ = try service.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: projectID.description,
                displayName: "Post-Commit Receipt Project",
                repositoryIdentity: nil,
                aliases: [projectRoot.path]
            ),
            canonicalRoot: projectRoot
        )
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "post-commit-receipt-client")
        _ = try service.bind(
            owner: owner,
            projectID: projectID,
            generation: .initial,
            authorizationScope: scope(root: projectRoot)
        )
        let context = try service.invocationContext(for: owner, clientID: ClientID(owner.id))
        let repositoryCommitted = DispatchSemaphore(value: 0)
        let releaseRepositoryResult = DispatchSemaphore(value: 0)
        await service.repository.configureOperationObservers(didCommit: {
            repositoryCommitted.signal()
            _ = releaseRepositoryResult.wait(timeout: .now() + 1)
        })
        let probe = MutationProbe()
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        let startedAt = Date()

        let result: String = try service.commitIfCurrent(
            context: context,
            resultKind: "post-commit-result-gate",
            cancellation: cancellation
        ) { control in
            try control.withCommitAuthorization {
                probe.increment()
                return "committed-result"
            }
        }

        XCTAssertEqual(repositoryCommitted.wait(timeout: .now()), .success)
        XCTAssertEqual(result, "committed-result")
        XCTAssertEqual(probe.value, 1)
        XCTAssertTrue(cancellation.isDeadlineExceeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        releaseRepositoryResult.signal()
        XCTAssertNotNil(try service.project(projectID))
    }

    func testProjectMemoryMutationReconcilesOuterToolResultWhilePostCommitIsBlocked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-project-memory-tool-result-receipt-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let mutationCommitted = DispatchSemaphore(value: 0)
        let releasePostCommit = DispatchSemaphore(value: 0)
        let memory = ProjectMemoryService(
            paths: paths,
            clock: SystemClock(),
            limits: .current,
            afterIdentityMetadataWriteObserver: nil,
            didIdentityRegistryCommitObserver: nil,
            beforeContinuityProjectionWriteObserver: nil,
            beforeExportCommitObserver: nil,
            didMutationCommitObserver: {
                mutationCommitted.signal()
                _ = releasePostCommit.wait(timeout: .now() + 1)
            }
        )
        let service = try ProjectContextService(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3"),
            waitTimeout: .milliseconds(50),
            cancellationCleanupTimeout: .milliseconds(25)
        )
        defer {
            releasePostCommit.signal()
            memory.closeAll()
            service.close()
            try? FileManager.default.removeItem(at: root)
        }

        let initialized = try memory.initializeUnchecked(path: projectRoot.path)
        let rawProjectID = try XCTUnwrap(initialized["project_id"] as? String)
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: rawProjectID)))
        _ = try service.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: rawProjectID,
                displayName: "Committed Memory Result",
                repositoryIdentity: nil,
                aliases: [projectRoot.path]
            ),
            canonicalRoot: projectRoot
        )
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "memory-receipt-client")
        _ = try service.bind(
            owner: owner,
            projectID: projectID,
            generation: .initial,
            authorizationScope: scope(root: projectRoot, tools: ["project_memory.remember"])
        )
        let context = try service.invocationContext(for: owner, clientID: ClientID(owner.id))
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        let startedAt = Date()

        let result: ToolResult = try service.commitIfCurrent(
            context: context,
            resultKind: "project_memory.remember",
            cancellation: cancellation
        ) { control in
            ToolResult.success(try memory.remember(
                projectID: rawProjectID,
                write: ProjectMemoryWrite(
                    kind: "fact",
                    title: "Durable tool result",
                    summary: "the outer response survives a post-COMMIT stall"
                ),
                cancellation: control
            ))
        }

        XCTAssertEqual(mutationCommitted.wait(timeout: .now()), .success)
        XCTAssertTrue(result.ok)
        XCTAssertNotNil(result.payload["record_id"] as? String)
        XCTAssertTrue(cancellation.isDeadlineExceeded)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        releasePostCommit.signal()
        let recordID = try XCTUnwrap(result.payload["record_id"] as? String)
        let stored = try memory.get(
            projectID: rawProjectID,
            ids: [recordID],
            includeBody: false
        )
        XCTAssertEqual((stored["records"] as? [[String: Any]])?.count, 1)
    }

    func testCommitIfCurrentKeepsMutationOutcomeAfterItsIrreversibleBoundary() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("irreversible-project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Irreversible Project",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "irreversible-client")
            _ = try await repository.bind(
                owner: owner,
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope(root: projectRoot)
            )
            let context = try await repository.invocationContext(for: owner)
            let cancellation = ToolCallCancellation()

            let result = try await repository.commitIfCurrent(
                context: context,
                owner: owner,
                resultKind: "external-write",
                cancellation: cancellation
            ) {
                cancellation.cancel()
                return "durable-result"
            }

            XCTAssertTrue(cancellation.isCancelled)
            XCTAssertEqual(result, "durable-result")
        }
    }

    func testRegistrationRefreshesExactMetadataButRequiresRelinkForMovedRoot() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("registered-project", isDirectory: true)
            let first = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Initial Name",
                canonicalRoot: projectRoot,
                repositoryFingerprint: "first"
            )
            let refreshed = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Current Name",
                canonicalRoot: projectRoot,
                repositoryFingerprint: "second",
                bookmarkReference: "bookmark-reference"
            )
            XCTAssertEqual(refreshed.projectID, first.projectID)
            XCTAssertEqual(refreshed.generation, first.generation)
            XCTAssertEqual(refreshed.createdAt, first.createdAt)
            XCTAssertEqual(refreshed.displayName, "Current Name")
            XCTAssertEqual(refreshed.repositoryFingerprint, "second")
            XCTAssertEqual(refreshed.bookmarkReference, "bookmark-reference")

            await assertContextError(code: "project_root_already_registered") {
                _ = try await repository.registerProjectUnchecked(
                    projectID: ProjectID(),
                    displayName: "Conflicting Project",
                    canonicalRoot: projectRoot
                )
            }

            let movedRoot = root.appendingPathComponent("moved-project", isDirectory: true)
            await assertContextError(code: "project_relink_required") {
                _ = try await repository.registerProjectUnchecked(
                    projectID: projectID,
                    displayName: "Moved",
                    canonicalRoot: movedRoot
                )
            }
        }
    }

    func testTransitionAuthorityIsIndependentOfAuditEventRetention() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent(
                "authority-audit-independence",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            let fingerprint = "git:fixture/authority-audit-independence"
            let operationID = transitionOperationID(1)
            let target = ProjectIdentityTarget(
                canonicalRoot: projectRoot,
                repositoryIdentity: fingerprint,
                directoryIdentity: try projectDirectoryIdentity(projectRoot)
            )

            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Authority Audit Independence",
                canonicalRoot: projectRoot,
                repositoryFingerprint: fingerprint,
                controlExpectation: .absent,
                targetDirectoryIdentity: target.directoryIdentity,
                disposition: .awaitingIdentityPublication,
                transitionOperationID: operationID
            )
            try await repository.removeProjectTransitionEventsForTesting(
                projectID: projectID,
                eventType: "project_registration_staged",
                operationID: operationID
            )

            try await repository.validateRegistrationPublicationAuthority(
                projectID: projectID,
                generation: .initial,
                target: target,
                transitionOperationID: operationID
            )
            let activated = try await repository.finalizeRegistration(
                projectID: projectID,
                generation: .initial,
                target: target,
                transitionOperationID: operationID
            )
            XCTAssertEqual(activated.lifecycleState, .active)

            try await repository.removeProjectTransitionEventsForTesting(
                projectID: projectID,
                eventType: "project_registration_published",
                operationID: operationID
            )
            let replayed = try await repository.finalizeRegistration(
                projectID: projectID,
                generation: .initial,
                target: target,
                transitionOperationID: operationID
            )
            XCTAssertEqual(replayed, activated)
            let counts = try await repository.projectTransitionAuthorityCountsForTesting(
                projectID: projectID
            )
            XCTAssertEqual(counts.staged, 0)
            XCTAssertEqual(counts.published, 1)
            XCTAssertEqual(counts.total, 1)
        }
    }

    func testMissingAndCorruptTransitionAuthorityFailClosed() async throws {
        try await withRepository { repository, root in
            let missingProjectID = ProjectID()
            let missingRoot = root.appendingPathComponent(
                "missing-registration-authority",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: missingRoot,
                withIntermediateDirectories: true
            )
            let missingOperationID = transitionOperationID(2)
            let missingTarget = ProjectIdentityTarget(
                canonicalRoot: missingRoot,
                repositoryIdentity: "git:fixture/missing-authority",
                directoryIdentity: try projectDirectoryIdentity(missingRoot)
            )
            _ = try await repository.registerProjectUnchecked(
                projectID: missingProjectID,
                displayName: "Missing Authority",
                canonicalRoot: missingRoot,
                repositoryFingerprint: missingTarget.repositoryIdentity,
                controlExpectation: .absent,
                targetDirectoryIdentity: missingTarget.directoryIdentity,
                disposition: .awaitingIdentityPublication,
                transitionOperationID: missingOperationID
            )
            try await repository.removeProjectTransitionAuthorityForTesting(
                projectID: missingProjectID,
                transitionKind: "registration",
                operationID: missingOperationID
            )

            await assertContextError(code: "project_transition_conflict") {
                try await repository.validateRegistrationPublicationAuthority(
                    projectID: missingProjectID,
                    generation: .initial,
                    target: missingTarget,
                    transitionOperationID: missingOperationID
                )
            }
            await assertContextError(code: "project_transition_conflict") {
                _ = try await repository.finalizeRegistration(
                    projectID: missingProjectID,
                    generation: .initial,
                    target: missingTarget,
                    transitionOperationID: missingOperationID
                )
            }
            let missingProject = try await repository.project(missingProjectID)
            XCTAssertEqual(missingProject?.lifecycleState, .maintenance)

            let corruptProjectID = ProjectID()
            let originalRoot = root.appendingPathComponent(
                "corrupt-relink-original",
                isDirectory: true
            )
            let replacementRoot = root.appendingPathComponent(
                "corrupt-relink-replacement",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: originalRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: replacementRoot,
                withIntermediateDirectories: true
            )
            let fingerprint = "git:fixture/corrupt-authority"
            _ = try await repository.registerProjectUnchecked(
                projectID: corruptProjectID,
                displayName: "Corrupt Authority",
                canonicalRoot: originalRoot,
                repositoryFingerprint: fingerprint
            )
            let corruptOperationID = transitionOperationID(3)
            let corruptTarget = ProjectIdentityTarget(
                canonicalRoot: replacementRoot,
                repositoryIdentity: fingerprint,
                directoryIdentity: try projectDirectoryIdentity(replacementRoot)
            )
            _ = try await repository.relinkProjectUnchecked(
                projectID: corruptProjectID,
                expectedGeneration: .initial,
                newCanonicalRoot: replacementRoot,
                repositoryFingerprint: fingerprint,
                targetDirectoryIdentity: corruptTarget.directoryIdentity,
                disposition: .awaitingIdentityPublication,
                transitionOperationID: corruptOperationID
            )
            try await repository.mutateProjectTransitionAuthorityForTesting(
                projectID: corruptProjectID,
                transitionKind: "relink",
                operationID: corruptOperationID,
                field: "authority_sha256",
                value: String(repeating: "0", count: 64)
            )

            await assertContextError(code: "project_transition_conflict") {
                try await repository.validateRelinkPublicationAuthority(
                    projectID: corruptProjectID,
                    priorGeneration: .initial,
                    target: corruptTarget,
                    transitionOperationID: corruptOperationID
                )
            }
            await assertContextError(code: "project_transition_conflict") {
                _ = try await repository.finalizeRelink(
                    projectID: corruptProjectID,
                    priorGeneration: .initial,
                    target: corruptTarget,
                    transitionOperationID: corruptOperationID
                )
            }
            let corruptProject = try await repository.project(corruptProjectID)
            XCTAssertEqual(corruptProject?.lifecycleState, .maintenance)
            XCTAssertEqual(corruptProject?.generation, ProjectGeneration(2))
            XCTAssertEqual(
                corruptProject?.canonicalRoot,
                replacementRoot.standardizedFileURL
            )
        }
    }

    func testPublishedTransitionAuthorityRetentionIsBoundedAndNeverPrunesStaged() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let fingerprint = "git:fixture/authority-retention"
            var generation = ProjectGeneration.initial
            let initialRoot = root.appendingPathComponent("retention-root-0", isDirectory: true)
            try FileManager.default.createDirectory(
                at: initialRoot,
                withIntermediateDirectories: true
            )
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Authority Retention",
                canonicalRoot: initialRoot,
                repositoryFingerprint: fingerprint
            )

            let publishedTransitionCount =
                ProjectControlPlaneRepository.maximumPublishedProjectTransitionAuthoritiesPerProject + 2
            for index in 1...publishedTransitionCount {
                let replacementRoot = root.appendingPathComponent(
                    "retention-root-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: replacementRoot,
                    withIntermediateDirectories: true
                )
                let target = ProjectIdentityTarget(
                    canonicalRoot: replacementRoot,
                    repositoryIdentity: fingerprint,
                    directoryIdentity: try projectDirectoryIdentity(replacementRoot)
                )
                let operationID = transitionOperationID(index + 10)
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: generation,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: fingerprint,
                    targetDirectoryIdentity: target.directoryIdentity,
                    disposition: .awaitingIdentityPublication,
                    transitionOperationID: operationID
                )
                _ = try await repository.finalizeRelink(
                    projectID: projectID,
                    priorGeneration: generation,
                    target: target,
                    transitionOperationID: operationID
                )
                generation = ProjectGeneration(generation.rawValue + 1)
            }

            let bounded = try await repository.projectTransitionAuthorityCountsForTesting(
                projectID: projectID
            )
            XCTAssertEqual(bounded.staged, 0)
            XCTAssertEqual(
                bounded.published,
                ProjectControlPlaneRepository.maximumPublishedProjectTransitionAuthoritiesPerProject
            )

            let stagedRoot = root.appendingPathComponent(
                "retention-root-staged",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stagedRoot,
                withIntermediateDirectories: true
            )
            let stagedTarget = ProjectIdentityTarget(
                canonicalRoot: stagedRoot,
                repositoryIdentity: fingerprint,
                directoryIdentity: try projectDirectoryIdentity(stagedRoot)
            )
            _ = try await repository.relinkProjectUnchecked(
                projectID: projectID,
                expectedGeneration: generation,
                newCanonicalRoot: stagedRoot,
                repositoryFingerprint: fingerprint,
                targetDirectoryIdentity: stagedTarget.directoryIdentity,
                disposition: .awaitingIdentityPublication,
                transitionOperationID: transitionOperationID(publishedTransitionCount + 11)
            )
            let withStaged = try await repository.projectTransitionAuthorityCountsForTesting(
                projectID: projectID
            )
            XCTAssertEqual(withStaged.staged, 1)
            XCTAssertEqual(
                withStaged.published,
                ProjectControlPlaneRepository.maximumPublishedProjectTransitionAuthoritiesPerProject
            )
            XCTAssertEqual(
                withStaged.total,
                ProjectControlPlaneRepository.maximumPublishedProjectTransitionAuthoritiesPerProject + 1
            )
        }
    }

    func testTwoProjectsRemainIsolatedAndOwnersAreUnique() async throws {
        try await withRepository { repository, root in
            let projectA = ProjectID()
            let projectB = ProjectID()
            let rootA = root.appendingPathComponent("project-a", isDirectory: true)
            let rootB = root.appendingPathComponent("project-b", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectA,
                displayName: "Project A",
                canonicalRoot: rootA
            )
            _ = try await repository.registerProjectUnchecked(
                projectID: projectB,
                displayName: "Project B",
                canonicalRoot: rootB
            )

            let ownerA = ProjectBindingOwner(kind: .mcpClient, id: "client-a")
            let ownerB = ProjectBindingOwner(kind: .mcpClient, id: "client-b")
            let scopeA = scope(root: rootA, tools: ["project_memory.remember"])
            let scopeB = scope(root: rootB, tools: ["project_memory.search"])
            _ = try await repository.bind(
                owner: ownerA,
                projectID: projectA,
                generation: .initial,
                authorizationScope: scopeA
            )
            _ = try await repository.bind(
                owner: ownerB,
                projectID: projectB,
                generation: .initial,
                authorizationScope: scopeB
            )

            let contextA = try await repository.invocationContext(for: ownerA)
            let contextB = try await repository.invocationContext(for: ownerB)
            XCTAssertEqual(contextA.projectID, projectA)
            XCTAssertEqual(contextB.projectID, projectB)
            XCTAssertNotEqual(contextA.authorizationScope, contextB.authorizationScope)
            try await repository.validate(contextA, for: ownerA)
            try await repository.validate(contextB, for: ownerB)

            await assertContextError(code: "project_scope_mismatch") {
                try await repository.validate(contextB, for: ownerA)
            }
            await assertContextError(code: "binding_owner_conflict") {
                _ = try await repository.bind(
                    owner: ownerA,
                    projectID: projectB,
                    generation: .initial,
                    authorizationScope: scopeB
                )
            }
        }
    }

    func testMissingOwnerContextReturnsStableRequiredCode() async throws {
        try await withRepository { repository, _ in
            let missing = ProjectBindingOwner(kind: .agentSession, id: "missing-session")
            await assertContextError(code: "project_context_required") {
                _ = try await repository.invocationContext(for: missing)
            }
        }
    }

    func testRelinkMovesQuiescentProjectAndAdvancesGenerationFence() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let originalRoot = root.appendingPathComponent("relink-original", isDirectory: true)
            let replacementRoot = root.appendingPathComponent("relink-replacement", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Relink Project",
                canonicalRoot: originalRoot,
                repositoryFingerprint: "git:fixture/relink"
            )

            let receipt = try await repository.relinkProjectUnchecked(
                projectID: projectID,
                expectedGeneration: .initial,
                newCanonicalRoot: replacementRoot,
                repositoryFingerprint: "git:fixture/relink"
            )
            XCTAssertEqual(receipt.projectID, projectID)
            XCTAssertEqual(receipt.priorCanonicalRoot.path, originalRoot.standardizedFileURL.path)
            XCTAssertEqual(receipt.newCanonicalRoot.path, replacementRoot.standardizedFileURL.path)
            XCTAssertEqual(receipt.priorGeneration, .initial)
            XCTAssertEqual(receipt.newGeneration, ProjectGeneration(2))
            XCTAssertEqual(receipt.invalidatedBindingCount, 0)

            let storedProject = try await repository.project(projectID)
            let project = try XCTUnwrap(storedProject)
            XCTAssertEqual(project.canonicalRoot.path, replacementRoot.standardizedFileURL.path)
            XCTAssertEqual(project.generation, ProjectGeneration(2))
            XCTAssertEqual(project.repositoryFingerprint, "git:fixture/relink")

            await assertContextError(code: "stale_project_generation") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: originalRoot,
                    repositoryFingerprint: "git:fixture/relink"
                )
            }
        }
    }

    func testRelinkFailsClosedWhileBoundOrWhenRepositoryIdentityChanges() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let originalRoot = root.appendingPathComponent("relink-busy-original", isDirectory: true)
            let replacementRoot = root.appendingPathComponent("relink-busy-replacement", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Busy Relink Project",
                canonicalRoot: originalRoot,
                repositoryFingerprint: "git:fixture/original"
            )
            _ = try await repository.bind(
                owner: ProjectBindingOwner(kind: .mcpClient, id: "relink-client"),
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope(root: originalRoot)
            )

            await assertContextError(code: "project_repository_identity_mismatch") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: "git:fixture/different"
                )
            }
            await assertContextError(code: "project_relink_busy") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: "git:fixture/original"
                )
            }
            let storedProject = try await repository.project(projectID)
            let unchanged = try XCTUnwrap(storedProject)
            XCTAssertEqual(unchanged.canonicalRoot.path, originalRoot.standardizedFileURL.path)
            XCTAssertEqual(unchanged.generation, .initial)
        }
    }

    func testRelinkCannotTakeAnotherRegisteredRoot() async throws {
        try await withRepository { repository, root in
            let firstID = ProjectID()
            let secondID = ProjectID()
            let firstRoot = root.appendingPathComponent("relink-first", isDirectory: true)
            let secondRoot = root.appendingPathComponent("relink-second", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: firstID,
                displayName: "First",
                canonicalRoot: firstRoot
            )
            _ = try await repository.registerProjectUnchecked(
                projectID: secondID,
                displayName: "Second",
                canonicalRoot: secondRoot
            )

            await assertContextError(code: "project_root_already_registered") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: firstID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: secondRoot,
                    repositoryFingerprint: nil
                )
            }
            let storedProject = try await repository.project(firstID)
            let unchanged = try XCTUnwrap(storedProject)
            XCTAssertEqual(unchanged.canonicalRoot.path, firstRoot.standardizedFileURL.path)
            XCTAssertEqual(unchanged.generation, .initial)
        }
    }

    func testRelinkRequiresEstablishedRepositoryIdentityOnBothSides() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let originalRoot = root.appendingPathComponent("relink-no-identity-original", isDirectory: true)
            let replacementRoot = root.appendingPathComponent("relink-no-identity-replacement", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Identity Required",
                canonicalRoot: originalRoot,
                repositoryFingerprint: nil
            )

            await assertContextError(code: "project_repository_identity_mismatch") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: nil
                )
            }
            await assertContextError(code: "project_repository_identity_mismatch") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: "git:caller-asserted"
                )
            }

            let storedProject = try await repository.project(projectID)
            let unchanged = try XCTUnwrap(storedProject)
            XCTAssertEqual(unchanged.canonicalRoot.path, originalRoot.standardizedFileURL.path)
            XCTAssertEqual(unchanged.generation, .initial)
        }
    }

    func testRelinkRefusesNonterminalAutonomousRunWithoutBindings() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let originalRoot = root.appendingPathComponent("relink-run-original", isDirectory: true)
            let replacementRoot = root.appendingPathComponent("relink-run-replacement", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Running Relink Project",
                canonicalRoot: originalRoot,
                repositoryFingerprint: "git:fixture/running"
            )
            _ = try await repository.createAutonomousRun(AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: .initial,
                mission: "Keep this generation active",
                providerID: "lmstudio",
                adapterID: "forge.native-session-host",
                modelKey: "fixture-model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["project_memory.search"],
                    completionGates: ["tests"]
                ),
                authorizationScope: scope(root: originalRoot)
            ))

            await assertContextError(code: "project_relink_busy") {
                _ = try await repository.relinkProjectUnchecked(
                    projectID: projectID,
                    expectedGeneration: .initial,
                    newCanonicalRoot: replacementRoot,
                    repositoryFingerprint: "git:fixture/running"
                )
            }
            let stored = try await repository.project(projectID)
            XCTAssertEqual(stored?.canonicalRoot.path, originalRoot.standardizedFileURL.path)
            XCTAssertEqual(stored?.generation, .initial)
        }
    }

    func testResetFencesStaleGenerationAndQuarantineIsBounded() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("reset-project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Reset Project",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "reset-client")
            _ = try await repository.bind(
                owner: owner,
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope(root: projectRoot)
            )
            let staleContext = try await repository.invocationContext(for: owner)

            let resetting = try await repository.beginReset(
                projectID: projectID,
                expectedGeneration: .initial
            )
            XCTAssertEqual(resetting.lifecycleState, .resetting)
            await assertContextError(code: "project_not_active") {
                try await repository.validate(staleContext, for: owner)
            }

            let receipt = try await repository.completeReset(
                projectID: projectID,
                expectedGeneration: .initial
            )
            XCTAssertEqual(receipt.priorGeneration, .initial)
            XCTAssertEqual(receipt.newGeneration, ProjectGeneration(2))
            XCTAssertEqual(receipt.invalidatedBindingCount, 1)
            await assertContextError(code: "stale_project_generation") {
                try await repository.validate(staleContext, for: owner)
            }

            for index in 0..<(ProjectControlPlaneRepository.maximumQuarantineEventsPerProject + 5) {
                _ = try await repository.quarantineStaleResult(
                    context: staleContext,
                    resultKind: "fixture-\(index)",
                    resultSHA256: String(repeating: "a", count: 64)
                )
            }
            let quarantineCount = try await repository.quarantineEventCount(projectID: projectID)
            XCTAssertEqual(
                quarantineCount,
                ProjectControlPlaneRepository.maximumQuarantineEventsPerProject
            )
        }
    }

    func testCommitIfCurrentSerializesMutationAndQuarantinesStaleResultOnce() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("commit-project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Commit Project",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "commit-client")
            _ = try await repository.bind(
                owner: owner,
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope(root: projectRoot)
            )
            let context = try await repository.invocationContext(for: owner)
            let probe = MutationProbe()
            let committed = try await repository.commitIfCurrent(
                context: context,
                owner: owner,
                resultKind: "memory-write",
                resultSHA256: String(repeating: "b", count: 64)
            ) {
                probe.increment()
                return "committed"
            }
            XCTAssertEqual(committed, "committed")
            XCTAssertEqual(probe.value, 1)

            _ = try await repository.beginReset(projectID: projectID, expectedGeneration: .initial)
            _ = try await repository.completeReset(projectID: projectID, expectedGeneration: .initial)
            await assertContextError(code: "stale_project_generation") {
                _ = try await repository.commitIfCurrent(
                    context: context,
                    owner: owner,
                    resultKind: "memory-write",
                    resultSHA256: String(repeating: "c", count: 64)
                ) {
                    probe.increment()
                    return "must-not-commit"
                }
            }
            XCTAssertEqual(probe.value, 1)
            let quarantineCount = try await repository.quarantineEventCount(projectID: projectID)
            XCTAssertEqual(quarantineCount, 1)
        }
    }

    func testResetInvalidatesBindingAndInactiveOwnerCanRebindToNewGeneration() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("binding-project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Binding Project",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .runtimeJob, id: UUID().uuidString.lowercased())
            let first = try await repository.bind(
                owner: owner,
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope(root: projectRoot, tools: ["shell_exec"])
            )
            _ = try await repository.beginReset(projectID: projectID, expectedGeneration: .initial)
            _ = try await repository.completeReset(projectID: projectID, expectedGeneration: .initial)

            let activeBinding = try await repository.binding(for: owner)
            XCTAssertNil(activeBinding)
            let storedBinding = try await repository.binding(for: owner, includeInactive: true)
            let inactive = try XCTUnwrap(storedBinding)
            XCTAssertFalse(inactive.active)
            await assertContextError(code: "project_context_required") {
                _ = try await repository.invocationContext(for: owner)
            }

            let rebound = try await repository.bind(
                owner: owner,
                projectID: projectID,
                generation: ProjectGeneration(2),
                authorizationScope: scope(root: projectRoot, tools: ["shell_exec"])
            )
            XCTAssertEqual(rebound.bindingID, first.bindingID)
            XCTAssertEqual(rebound.projectGeneration, ProjectGeneration(2))
            XCTAssertTrue(rebound.active)
        }
    }

    func testSchemaIntegrityPragmasAndMigrationReceiptAreIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-control-plane-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        do {
            let first = try ProjectControlPlaneRepository(databaseURL: databaseURL)
            let firstHealth = try await first.health()
            XCTAssertEqual(firstHealth.schemaVersion, 2)
            XCTAssertEqual(firstHealth.journalMode.lowercased(), "wal")
            XCTAssertTrue(firstHealth.foreignKeysEnabled)
            XCTAssertEqual(firstHealth.busyTimeoutMilliseconds, 5_000)
            XCTAssertEqual(firstHealth.integrityResult, "ok")
            let firstReceiptCount = try await first.migrationReceiptCount()
            XCTAssertEqual(firstReceiptCount, 1)
            await first.close()

            let reopened = try ProjectControlPlaneRepository(databaseURL: databaseURL)
            let reopenedReceiptCount = try await reopened.migrationReceiptCount()
            let reopenedHealth = try await reopened.health()
            XCTAssertEqual(reopenedReceiptCount, 1)
            XCTAssertEqual(reopenedHealth.schemaVersion, 2)
            await reopened.close()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testVersionTwoStoreAddsTransitionAuthoritySchemaWithoutEventBackfill() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "forge-control-plane-authority-schema-\(UUID().uuidString)",
                isDirectory: true
            )
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let projectID = ProjectID()
        let projectRoot = root.appendingPathComponent("existing-project", isDirectory: true)
        do {
            let repository = try ProjectControlPlaneRepository(databaseURL: databaseURL)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Existing Version Two Project",
                canonicalRoot: projectRoot,
                repositoryFingerprint: "git:fixture/existing-v2"
            )
            await repository.close()

            try executeControlPlaneFixture(
                at: databaseURL,
                sql: "DROP TABLE project_transition_authority;"
            )
            XCTAssertEqual(
                try controlPlaneFixtureInt(
                    at: databaseURL,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='project_transition_authority';"
                ),
                0
            )

            let reopened = try ProjectControlPlaneRepository(databaseURL: databaseURL)
            XCTAssertEqual(
                try controlPlaneFixtureInt(
                    at: databaseURL,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='project_transition_authority';"
                ),
                1
            )
            let reopenedProject = try await reopened.project(projectID)
            XCTAssertEqual(reopenedProject?.lifecycleState, .active)
            let authorityCounts = try await reopened.projectTransitionAuthorityCountsForTesting(
                projectID: projectID
            )
            XCTAssertEqual(authorityCounts.total, 0)
            await reopened.close()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testUnshippedAndUnversionedControlPlaneSchemasFailClosedWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-control-plane-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let versionOneURL = root.appendingPathComponent("version-one.sqlite3")
        try createLegacyControlPlaneFixture(at: versionOneURL, userVersion: 1)
        let versionOneBefore = try controlPlaneFixtureSnapshot(at: versionOneURL)
        XCTAssertThrowsError(try ProjectControlPlaneRepository(databaseURL: versionOneURL)) { error in
            XCTAssertEqual((error as? ProjectContextError)?.code, "unsupported_schema_version")
        }
        let versionOneAfter = try controlPlaneFixtureSnapshot(at: versionOneURL)
        XCTAssertEqual(versionOneAfter.databaseBytes, versionOneBefore.databaseBytes)
        XCTAssertEqual(versionOneAfter.journalMode, versionOneBefore.journalMode)
        XCTAssertEqual(versionOneAfter.sidecars, versionOneBefore.sidecars)
        XCTAssertEqual(try controlPlaneFixtureInt(at: versionOneURL, sql: "PRAGMA user_version;"), 1)
        XCTAssertEqual(
            try controlPlaneFixtureInt(at: versionOneURL, sql: "SELECT value FROM legacy_marker WHERE id=1;"),
            41
        )

        let unversionedURL = root.appendingPathComponent("unversioned.sqlite3")
        try createLegacyControlPlaneFixture(at: unversionedURL, userVersion: 0)
        let unversionedBefore = try controlPlaneFixtureSnapshot(at: unversionedURL)
        XCTAssertThrowsError(try ProjectControlPlaneRepository(databaseURL: unversionedURL)) { error in
            XCTAssertEqual((error as? ProjectContextError)?.code, "integrity_failure")
        }
        let unversionedAfter = try controlPlaneFixtureSnapshot(at: unversionedURL)
        XCTAssertEqual(unversionedAfter.databaseBytes, unversionedBefore.databaseBytes)
        XCTAssertEqual(unversionedAfter.journalMode, unversionedBefore.journalMode)
        XCTAssertEqual(unversionedAfter.sidecars, unversionedBefore.sidecars)
        XCTAssertEqual(try controlPlaneFixtureInt(at: unversionedURL, sql: "PRAGMA user_version;"), 0)
        XCTAssertEqual(
            try controlPlaneFixtureInt(at: unversionedURL, sql: "SELECT value FROM legacy_marker WHERE id=1;"),
            41
        )

        let viewOnlyURL = root.appendingPathComponent("view-only.sqlite3")
        try createViewOnlyControlPlaneFixture(at: viewOnlyURL)
        let viewOnlyBytes = try Data(contentsOf: viewOnlyURL)
        XCTAssertThrowsError(try ProjectControlPlaneRepository(databaseURL: viewOnlyURL)) { error in
            XCTAssertEqual((error as? ProjectContextError)?.code, "integrity_failure")
        }
        XCTAssertEqual(try Data(contentsOf: viewOnlyURL), viewOnlyBytes)
        XCTAssertEqual(
            try controlPlaneFixtureInt(
                at: viewOnlyURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='view' AND name='foreign_view';"
            ),
            1
        )
        XCTAssertEqual(try controlPlaneFixtureInt(at: viewOnlyURL, sql: "PRAGMA user_version;"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewOnlyURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewOnlyURL.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewOnlyURL.path + "-journal"))

        let freshURL = root.appendingPathComponent("fresh.sqlite3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path))
        let fresh = try ProjectControlPlaneRepository(databaseURL: freshURL)
        let freshHealth = try await fresh.health()
        XCTAssertEqual(freshHealth.schemaVersion, ProjectControlPlaneRepository.schemaVersion)
        XCTAssertEqual(freshHealth.journalMode.lowercased(), "wal")
        XCTAssertEqual(freshHealth.integrityResult, "ok")
        await fresh.close()
        XCTAssertEqual(
            try controlPlaneFixtureInt(at: freshURL, sql: "PRAGMA user_version;"),
            ProjectControlPlaneRepository.schemaVersion
        )
    }

    func testInvalidGenerationAndAuthorizationScopeAreRejectedBeforePersistence() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("validation-project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Validation Project",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "validation-client")
            await assertContextError(code: "invalid_project_generation") {
                _ = try await repository.bind(
                    owner: owner,
                    projectID: projectID,
                    generation: ProjectGeneration(0),
                    authorizationScope: self.scope(root: projectRoot)
                )
            }
            await assertContextError(code: "invalid_authorization_scope") {
                _ = try await repository.bind(
                    owner: owner,
                    projectID: projectID,
                    generation: .initial,
                    authorizationScope: ToolAuthorizationScope(
                        canonicalRoots: [],
                        allowedTools: [],
                        networkAllowed: false,
                        maximumInlineOutputBytes: 0
                    )
                )
            }
            let binding = try await repository.binding(for: owner, includeInactive: true)
            XCTAssertNil(binding)
        }
    }

    private func scope(
        root: URL,
        tools: Set<String> = ["project_memory.search"],
        maximumInlineOutputBytes: Int = 64 * 1_024
    ) -> ToolAuthorizationScope {
        ToolAuthorizationScope(
            canonicalRoots: [root],
            allowedTools: tools,
            networkAllowed: false,
            maximumInlineOutputBytes: maximumInlineOutputBytes
        )
    }

    private func projectDirectoryIdentity(_ url: URL) throws -> ProjectDirectoryIdentity {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_dev >= 0,
              information.st_ino > 0 else {
            throw ControlPlaneFixtureError.sqlite(
                "could not capture directory identity for \(url.path)"
            )
        }
        return ProjectDirectoryIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func transitionOperationID(_ value: Int) -> String {
        let suffix = String(value, radix: 16)
        precondition(suffix.count <= 64)
        return String(repeating: "0", count: 64 - suffix.count) + suffix
    }

    private func withRepository(
        busyTimeoutMilliseconds: Int = 5_000,
        _ body: (ProjectControlPlaneRepository, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-control-plane-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3"),
            clock: FixedClock(Date(timeIntervalSince1970: 1_000)),
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        do {
            try await body(repository, root)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func assertContextError(
        code: String,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected project context error \(code)", file: file, line: line)
        } catch let error as ProjectContextError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

extension ProjectControlPlaneRepository {
    func appendProjectTransitionEventForTesting(
        projectID: ProjectID,
        eventType: String,
        metadata: [String: String]
    ) throws {
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        )
        guard metadataData.count <= 2_048,
              let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            throw ProjectContextError.databaseFailure(
                "event metadata exceeds the bounded payload"
            )
        }
        try ControlPlaneTransitionFixtureDatabase.withTransaction(at: databaseURL) { database in
            let eventID = UUID().uuidString.lowercased()
            let severity = "info"
            let summary = "Project transition adversarial test fixture"
            let createdAt = ISO8601.string(from: Date())
            let previous = try database.scalarText(
                "SELECT event_sha256 FROM autonomy_events ORDER BY sequence DESC LIMIT 1"
            )
            let eventSHA256 = JSONSupport.sha256Hex(
                [
                    eventID,
                    projectID.description,
                    eventType,
                    severity,
                    summary,
                    metadataJSON,
                    previous ?? "",
                    createdAt,
                ].joined(separator: "|")
            )
            try database.execute(
                """
                INSERT INTO autonomy_events(
                    event_id,project_id,event_type,severity,summary,metadata_json,
                    previous_event_sha256,event_sha256,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?)
                """,
                bindings: [
                    eventID,
                    projectID.description,
                    eventType,
                    severity,
                    summary,
                    metadataJSON,
                    previous,
                    eventSHA256,
                    createdAt,
                ]
            )
        }
    }

    func removeProjectTransitionEventsForTesting(
        projectID: ProjectID,
        eventType: String,
        operationID: String
    ) throws {
        try requireControlPlaneTransitionOperationID(
            operationID,
            field: "project transition operation identifier"
        )
        try ControlPlaneTransitionFixtureDatabase.withTransaction(at: databaseURL) { database in
            try database.execute(
                """
                DELETE FROM autonomy_events
                WHERE project_id=? AND event_type=? AND instr(metadata_json,?)>0
                """,
                bindings: [
                    projectID.description,
                    eventType,
                    "\"operation_id\":\"\(operationID)\"",
                ]
            )
        }
    }

    func removeProjectTransitionAuthorityForTesting(
        projectID: ProjectID,
        transitionKind: String,
        operationID: String
    ) throws {
        try requireControlPlaneTransitionSelector(
            transitionKind: transitionKind,
            operationID: operationID
        )
        try ControlPlaneTransitionFixtureDatabase.withTransaction(at: databaseURL) { database in
            try database.execute(
                """
                DELETE FROM project_transition_authority
                WHERE project_id=? AND transition_kind=? AND operation_id=?
                """,
                bindings: [projectID.description, transitionKind, operationID]
            )
        }
    }

    func mutateProjectTransitionAuthorityForTesting(
        projectID: ProjectID,
        transitionKind: String,
        operationID: String,
        field: String,
        value: String
    ) throws {
        try requireControlPlaneTransitionSelector(
            transitionKind: transitionKind,
            operationID: operationID
        )
        let column: String
        switch field {
        case "target_root_sha256", "repository_identity_sha256", "directory_device",
             "directory_inode", "authority_sha256":
            column = field
        default:
            throw ProjectContextError.invalidIdentifier(
                "project transition authority test field"
            )
        }
        try ControlPlaneTransitionFixtureDatabase.withTransaction(at: databaseURL) { database in
            try database.execute(
                """
                UPDATE project_transition_authority SET \(column)=?
                WHERE project_id=? AND transition_kind=? AND operation_id=?
                """,
                bindings: [value, projectID.description, transitionKind, operationID]
            )
        }
    }

    func projectTransitionAuthorityCountsForTesting(
        projectID: ProjectID
    ) throws -> (staged: Int, published: Int, total: Int) {
        let database = try ControlPlaneTransitionFixtureDatabase(databaseURL: databaseURL)
        let staged = try database.scalarInt(
            """
            SELECT COUNT(*) FROM project_transition_authority
            WHERE project_id=? AND state='staged'
            """,
            bindings: [projectID.description]
        )
        let published = try database.scalarInt(
            """
            SELECT COUNT(*) FROM project_transition_authority
            WHERE project_id=? AND state='published'
            """,
            bindings: [projectID.description]
        )
        return (staged, published, staged + published)
    }

    private func requireControlPlaneTransitionSelector(
        transitionKind: String,
        operationID: String
    ) throws {
        guard transitionKind == "registration" || transitionKind == "relink" else {
            throw ProjectContextError.invalidIdentifier(
                "project transition authority test selector"
            )
        }
        try requireControlPlaneTransitionOperationID(
            operationID,
            field: "project transition authority test selector"
        )
    }

    private func requireControlPlaneTransitionOperationID(
        _ operationID: String,
        field: String
    ) throws {
        let range = operationID.startIndex..<operationID.endIndex
        guard operationID.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) == range else {
            throw ProjectContextError.invalidIdentifier(field)
        }
    }
}

private enum ControlPlaneFixtureError: Error {
    case sqlite(String)
}

private final class ControlPlaneTransitionFixtureDatabase {
    private static let busyTimeoutMilliseconds: Int32 = 5_000
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "could not open control-plane fixture"
            if let database { sqlite3_close_v2(database) }
            self.database = nil
            throw ControlPlaneFixtureError.sqlite(message)
        }
        guard sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_close_v2(database)
            self.database = nil
            throw ControlPlaneFixtureError.sqlite(message)
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    static func withTransaction(
        at databaseURL: URL,
        _ body: (ControlPlaneTransitionFixtureDatabase) throws -> Void
    ) throws {
        let fixture = try ControlPlaneTransitionFixtureDatabase(databaseURL: databaseURL)
        try fixture.executeStatic("BEGIN IMMEDIATE;")
        do {
            try body(fixture)
            try fixture.executeStatic("COMMIT;")
        } catch {
            try? fixture.executeStatic("ROLLBACK;")
            throw error
        }
    }

    func execute(_ sql: String, bindings: [String?] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw sqliteError(result)
            }
        }
    }

    func scalarInt(_ sql: String, bindings: [String?] = []) throws -> Int {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                throw sqliteError(result)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func scalarText(_ sql: String, bindings: [String?] = []) throws -> String? {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw sqliteError(result)
            }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }

    private func executeStatic(_ sql: String) throws {
        guard let database else {
            throw ControlPlaneFixtureError.sqlite("control-plane fixture is closed")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ControlPlaneFixtureError.sqlite(message)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [String?],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else {
            throw ControlPlaneFixtureError.sqlite("control-plane fixture is closed")
        }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw sqliteError(prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            if let binding {
                bindResult = binding.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, Self.transient)
                }
            } else {
                bindResult = sqlite3_bind_null(statement, index)
            }
            guard bindResult == SQLITE_OK else {
                throw sqliteError(bindResult)
            }
        }
        return try body(statement)
    }

    private func sqliteError(_ result: Int32) -> ControlPlaneFixtureError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite fixture failed with status \(result)"
        return .sqlite(message)
    }
}

private struct ControlPlaneFixtureSnapshot: Equatable {
    let databaseBytes: Data
    let journalMode: String
    let sidecars: [ControlPlaneSidecarSnapshot]
}

private struct ControlPlaneSidecarSnapshot: Equatable {
    let suffix: String
    let exists: Bool
    let bytes: Data?
}

private final class ControlPlaneWriteLock {
    private var database: OpaquePointer?
    private var isReleased = false

    init(databaseURL: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite open error"
            if let database { sqlite3_close(database) }
            throw ControlPlaneFixtureError.sqlite(message)
        }
        do {
            try Self.execute(database, sql: "BEGIN IMMEDIATE;")
        } catch {
            sqlite3_close(database)
            self.database = nil
            throw error
        }
    }

    deinit {
        release()
    }

    func release() {
        guard !isReleased, let database else { return }
        _ = sqlite3_exec(database, "COMMIT;", nil, nil, nil)
        sqlite3_close(database)
        self.database = nil
        isReleased = true
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw ControlPlaneFixtureError.sqlite(message)
        }
    }
}

private func controlPlaneFixtureSnapshot(at url: URL) throws -> ControlPlaneFixtureSnapshot {
    let fileManager = FileManager.default
    let sidecars = try ["-wal", "-shm", "-journal"].map { suffix in
        let sidecarURL = URL(fileURLWithPath: url.path + suffix)
        let exists = fileManager.fileExists(atPath: sidecarURL.path)
        return ControlPlaneSidecarSnapshot(
            suffix: suffix,
            exists: exists,
            bytes: exists ? try Data(contentsOf: sidecarURL) : nil
        )
    }
    return ControlPlaneFixtureSnapshot(
        databaseBytes: try Data(contentsOf: url),
        journalMode: try controlPlaneFixtureText(at: url, sql: "PRAGMA journal_mode;"),
        sidecars: sidecars
    )
}

private func executeControlPlaneFixture(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ControlPlaneFixtureError.sqlite("could not open control-plane fixture")
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) }
            ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(message)
        throw ControlPlaneFixtureError.sqlite(detail)
    }
}

private func createLegacyControlPlaneFixture(at url: URL, userVersion: Int) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ControlPlaneFixtureError.sqlite("could not open legacy fixture")
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(
        database,
        "CREATE TABLE legacy_marker(id INTEGER PRIMARY KEY,value INTEGER NOT NULL);"
            + "INSERT INTO legacy_marker(id,value) VALUES(1,41);"
            + "PRAGMA user_version=\(userVersion);",
        nil,
        nil,
        &message
    )
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) }
            ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(message)
        throw ControlPlaneFixtureError.sqlite(detail)
    }
}

private func createViewOnlyControlPlaneFixture(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ControlPlaneFixtureError.sqlite("could not open view-only fixture")
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(
        database,
        "CREATE VIEW foreign_view AS SELECT 1 AS value; PRAGMA user_version=0;",
        nil,
        nil,
        &message
    )
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) }
            ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(message)
        throw ControlPlaneFixtureError.sqlite(detail)
    }
}

private func controlPlaneFixtureInt(at url: URL, sql: String) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ControlPlaneFixtureError.sqlite("could not reopen legacy fixture")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ControlPlaneFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw ControlPlaneFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func controlPlaneFixtureText(at url: URL, sql: String) throws -> String {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw ControlPlaneFixtureError.sqlite("could not reopen legacy fixture")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ControlPlaneFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        throw ControlPlaneFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return String(cString: value)
}

private final class MutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

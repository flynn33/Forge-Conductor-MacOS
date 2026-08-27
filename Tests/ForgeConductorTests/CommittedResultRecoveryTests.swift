import XCTest
@testable import ForgeConductorCore

final class CommittedResultRecoveryTests: XCTestCase {
    func testNewIdentityCancellationRollsBackMetadataBeforeRegistryCommit() throws {
        let fixture = try makeProjectFixture(label: "identity-new-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cancellation = ToolCallCancellation()
        let resolver = ProjectIdentityResolver(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            afterMetadataWriteObserver: {
                cancellation.cancel()
            },
            didRegistryCommitObserver: nil
        )

        XCTAssertThrowsError(
            try resolver.initialize(
                path: fixture.project.path,
                projectID: nil,
                displayName: "Cancelled identity",
                repositoryIdentity: nil,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.projectRegistry.path))
        let projectEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertFalse(projectEntries.contains { UUID(uuidString: $0.lastPathComponent) != nil })

        let retried = try ProjectIdentityResolver(paths: fixture.paths).initialize(
            path: fixture.project.path,
            projectID: nil,
            displayName: "Recovered identity",
            repositoryIdentity: nil
        )
        XCTAssertEqual(retried.displayName, "Recovered identity")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.projectRegistry.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.projectsDir
                    .appendingPathComponent(retried.id, isDirectory: true)
                    .appendingPathComponent("project.json").path
            )
        )
    }

    func testIdentityIntentRollsBackInterruptedMetadataBeforeNextUpdate() throws {
        let fixture = try makeProjectFixture(label: "identity-intent-recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let interrupted = ProjectIdentityResolver(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            afterMetadataWriteObserver: {
                throw ProjectIdentityPersistenceInterruption.afterMetadataWrite
            },
            didRegistryCommitObserver: nil
        )

        XCTAssertThrowsError(
            try interrupted.initialize(
                path: fixture.project.path,
                projectID: nil,
                displayName: "Interrupted identity",
                repositoryIdentity: nil
            )
        ) { error in
            XCTAssertTrue(
                error is ProjectIdentityPersistenceInterruption,
                "unexpected error: \(error)"
            )
        }
        let intent = fixture.paths.projectsDir.appendingPathComponent(".identity-update.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.projectRegistry.path))

        let recovered = try ProjectIdentityResolver(paths: fixture.paths).initialize(
            path: fixture.project.path,
            projectID: nil,
            displayName: "Recovered identity",
            repositoryIdentity: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: intent.path))
        XCTAssertEqual(recovered.displayName, "Recovered identity")
        let identityDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(identityDirectories.map(\.lastPathComponent), [recovered.id])
    }

    func testExistingIdentityMetadataIsRestoredWhenRegistryUpdateDoesNotCommit() throws {
        let fixture = try makeProjectFixture(label: "identity-update-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalResolver = ProjectIdentityResolver(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 100))
        )
        let original = try originalResolver.initialize(
            path: fixture.project.path,
            projectID: nil,
            displayName: "Original identity",
            repositoryIdentity: nil
        )
        let metadataURL = fixture.paths.projectsDir
            .appendingPathComponent(original.id, isDirectory: true)
            .appendingPathComponent("project.json")
        let registryBefore = try Data(contentsOf: fixture.paths.projectRegistry)
        let metadataBefore = try Data(contentsOf: metadataURL)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.paths.projectsDir.path
            )
        }
        let failingResolver = ProjectIdentityResolver(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 200)),
            afterMetadataWriteObserver: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: fixture.paths.projectsDir.path
                )
            },
            didRegistryCommitObserver: nil
        )

        XCTAssertThrowsError(
            try failingResolver.initialize(
                path: fixture.project.path,
                projectID: original.id,
                displayName: "Uncommitted replacement",
                repositoryIdentity: nil
            )
        ) { error in
            XCTAssertFalse(error is CancellationError, "unexpected error: \(error)")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.paths.projectsDir.path
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.projectRegistry), registryBefore)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore)
        XCTAssertEqual(
            try originalResolver.descriptor(projectID: original.id).displayName,
            "Original identity"
        )
    }

    func testInitializeReturnsDescriptorWhenCancellationArrivesAfterRegistryCommit() throws {
        let fixture = try makeProjectFixture(label: "identity-committed-result")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cancellation = ToolCallCancellation()
        let memory = ProjectMemoryService(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            limits: .current,
            afterIdentityMetadataWriteObserver: nil,
            didIdentityRegistryCommitObserver: {
                cancellation.cancel()
            }
        )
        defer { memory.closeAll() }

        let response = try memory.initialize(
            path: fixture.project.path,
            displayName: "Committed identity",
            cancellation: cancellation
        )

        XCTAssertTrue(cancellation.isCancelled)
        let projectID = try XCTUnwrap(response["project_id"] as? String)
        XCTAssertEqual(
            (response["project"] as? [String: Any])?["display_name"] as? String,
            "Committed identity"
        )
        XCTAssertEqual(try memory.identities.descriptor(projectID: projectID).id, projectID)
        XCTAssertEqual(
            try memory.repositoryForProject(projectID).status()["record_count"] as? Int,
            0
        )
    }

    func testIdentityIntentRepairsMetadataAfterRegistryCommit() throws {
        let fixture = try makeProjectFixture(label: "identity-intent-commit-recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let intent = fixture.paths.projectsDir.appendingPathComponent(".identity-update.json")
        let savedIntent = fixture.root.appendingPathComponent("saved-identity-intent.json")
        let resolver = ProjectIdentityResolver(
            paths: fixture.paths,
            clock: FixedClock(Date(timeIntervalSince1970: 100)),
            afterMetadataWriteObserver: nil,
            didRegistryCommitObserver: {
                if let data = try? Data(contentsOf: intent) {
                    try? data.write(to: savedIntent)
                }
            }
        )
        let descriptor = try resolver.initialize(
            path: fixture.project.path,
            projectID: nil,
            displayName: "Committed identity",
            repositoryIdentity: nil
        )
        let metadata = fixture.paths.projectsDir
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent("project.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.moveItem(at: savedIntent, to: intent)

        let recovered = try ProjectIdentityResolver(paths: fixture.paths).descriptor(
            projectID: descriptor.id
        )

        XCTAssertEqual(recovered, descriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: intent.path))
    }

    func testV1PrepareReturnsCapturedResultWhenStorageFailsAfterCommit() throws {
        let fixture = try makeMemoryFixture(label: "v1-prepare-readback")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let databaseURL = try fixture.memory.repositoryForProject(fixture.projectID).databaseURL
        let backupURL = databaseURL.appendingPathExtension("committed")
        let cancellation = ToolCallCancellation()
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: nil,
            waitTimeout: .seconds(10),
            cancellationCleanupTimeout: .seconds(10),
            didPrepareDurableObserver: {
                cancellation.cancel()
                Self.replaceDatabaseWithDirectory(
                    memory: fixture.memory,
                    projectID: fixture.projectID,
                    databaseURL: databaseURL,
                    backupURL: backupURL
                )
            },
            didManagedCommandEnqueueObserver: nil
        )

        let response = try service.prepare(
            arguments: [
                "project_id": fixture.projectID,
                "predecessor_session_id": "v1-predecessor",
                "mission": "Return the committed V1 handoff",
            ],
            cancellation: cancellation
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(
            (response["operation"] as? [String: Any])?["state"] as? String,
            ContinuityState.checkpointPersisted.rawValue
        )
        XCTAssertNotNil((response["handoff"] as? [String: Any])?["handoff_id"] as? String)
        try assertDatabaseWasReplaced(databaseURL: databaseURL, backupURL: backupURL)
    }

    func testV1PrepareReplayReturnsThePreviouslyCommittedHandoff() throws {
        let fixture = try makeMemoryFixture(label: "v1-prepare-replay")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let service = ContinuityControlService(memory: fixture.memory)
        let operationID = UUID().uuidString.lowercased()
        let handoffID = UUID().uuidString.lowercased()
        let idempotencyKey = "v1-replay-\(operationID)"
        let first = try service.prepare(arguments: [
            "project_id": fixture.projectID,
            "operation_id": operationID,
            "handoff_id": handoffID,
            "idempotency_key": idempotencyKey,
            "predecessor_session_id": "v1-predecessor",
            "mission": "The committed mission",
        ])

        let replay = try service.prepare(arguments: [
            "project_id": fixture.projectID,
            "operation_id": UUID().uuidString.lowercased(),
            "handoff_id": UUID().uuidString.lowercased(),
            "idempotency_key": idempotencyKey,
            "predecessor_session_id": "v1-predecessor",
            "mission": "An uncommitted replay payload",
        ])

        XCTAssertEqual(
            (first["operation"] as? [String: Any])?["operation_id"] as? String,
            operationID
        )
        XCTAssertEqual(
            (replay["operation"] as? [String: Any])?["operation_id"] as? String,
            operationID
        )
        XCTAssertEqual(
            (replay["handoff"] as? [String: Any])?["handoff_id"] as? String,
            handoffID
        )
        XCTAssertEqual(
            (replay["handoff"] as? [String: Any])?["mission"] as? String,
            "The committed mission"
        )
    }

    func testV2PrepareReturnsCapturedResultWhenStorageFailsAfterCommit() throws {
        let fixture = try makeMemoryFixture(label: "v2-prepare-readback")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let databaseURL = try fixture.memory.repositoryForProject(fixture.projectID).databaseURL
        let backupURL = databaseURL.appendingPathExtension("committed")
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: nil,
            waitTimeout: .seconds(10),
            cancellationCleanupTimeout: .seconds(10),
            didPrepareDurableObserver: {
                Self.replaceDatabaseWithDirectory(
                    memory: fixture.memory,
                    projectID: fixture.projectID,
                    databaseURL: databaseURL,
                    backupURL: backupURL
                )
            },
            didManagedCommandEnqueueObserver: nil
        )
        let operationID = UUID().uuidString.lowercased()
        let arguments = continuityV2Arguments(
            fixture: fixture,
            operationID: operationID,
            mode: .externalMCPCompatibility
        )

        let response = try service.prepare(arguments: arguments)

        XCTAssertEqual(response["operation_id"] as? String, operationID)
        XCTAssertEqual(
            (response["operation"] as? [String: Any])?["state"] as? String,
            ContinuityState.checkpointPersisted.rawValue
        )
        XCTAssertEqual(
            (response["handoff"] as? [String: Any])?["operation_id"] as? String,
            operationID
        )
        try assertDatabaseWasReplaced(databaseURL: databaseURL, backupURL: backupURL)
    }

    func testV2PrepareReconcilesCanonicalStateWhenProjectionWritesFailAfterCommit() throws {
        let fixture = try makeMemoryFixture(label: "v2-projection-reconcile")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let repository = try fixture.memory.repositoryForProject(fixture.projectID)
        let continuityProjection = repository.directory
            .appendingPathComponent("continuity", isDirectory: true)
        try Data("projection path intentionally blocked".utf8).write(
            to: continuityProjection,
            options: .atomic
        )
        let handoff = try makeHandoffV2(projectID: fixture.projectID)

        let operation = try ContinuityStateEngine(memory: fixture.memory).prepareV2(
            handoff: handoff,
            predecessorSessionID: "predecessor",
            predecessorProviderResponseID: "response-predecessor",
            adapterID: "forge.native-session-host",
            idempotencyKey: "projection-reconcile-\(handoff.operationID)"
        )

        XCTAssertEqual(operation.state, .checkpointPersisted)
        XCTAssertEqual(
            try repository.continuityOperationV2(id: handoff.operationID)?.state,
            .checkpointPersisted
        )
        XCTAssertEqual(
            try repository.continuityHandoffV2(id: handoff.handoffID)?.contentSHA256,
            handoff.contentSHA256
        )
        var isDirectory: ObjCBool = true
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: continuityProjection.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertTrue(
            try repository.continuityProjectionRepairPending(
                operationID: handoff.operationID
            )
        )

        fixture.memory.closeProject(fixture.projectID)
        try FileManager.default.removeItem(at: continuityProjection)
        let reopened = try fixture.memory.repositoryForProject(fixture.projectID)
        XCTAssertFalse(
            try reopened.continuityProjectionRepairPending(
                operationID: handoff.operationID
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: continuityProjection
                    .appendingPathComponent("operations", isDirectory: true)
                    .appendingPathComponent("\(handoff.operationID).json").path
            )
        )
    }

    func testManagedRolloverReturnsCapturedOutcomeWhenStorageFailsAfterQueueCommit() async throws {
        let fixture = try makeMemoryFixture(label: "managed-queue-readback")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controlPlane = try ProjectControlPlaneRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite3")
        )
        let projectIdentity = ProjectID(try XCTUnwrap(UUID(uuidString: fixture.projectID)))
        _ = try await controlPlane.registerProject(
            projectID: projectIdentity,
            displayName: "Committed result fixture",
            canonicalRoot: fixture.project
        )
        let databaseURL = try fixture.memory.repositoryForProject(fixture.projectID).databaseURL
        let backupURL = databaseURL.appendingPathExtension("committed")
        let cancellation = ToolCallCancellation()
        let service = ContinuityControlService(
            memory: fixture.memory,
            controlPlane: controlPlane,
            waitTimeout: .seconds(10),
            cancellationCleanupTimeout: .seconds(10),
            didPrepareDurableObserver: nil,
            didManagedCommandEnqueueObserver: {
                cancellation.cancel()
                Self.replaceDatabaseWithDirectory(
                    memory: fixture.memory,
                    projectID: fixture.projectID,
                    databaseURL: databaseURL,
                    backupURL: backupURL
                )
            }
        )
        let operationID = UUID().uuidString.lowercased()

        let response = try service.requestRollover(
            arguments: continuityV2Arguments(
                fixture: fixture,
                operationID: operationID,
                mode: .managedAutonomous
            ),
            cancellation: cancellation
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(response["operation_id"] as? String, operationID)
        XCTAssertEqual(response["manager_operation_enqueued"] as? Bool, true)
        XCTAssertEqual(
            (response["handoff"] as? [String: Any])?["operation_id"] as? String,
            operationID
        )
        let readyCommandCount = try await controlPlane.readyContinuityCommandCount()
        XCTAssertEqual(readyCommandCount, 1)
        try assertDatabaseWasReplaced(databaseURL: databaseURL, backupURL: backupURL)
        await controlPlane.close()
    }

    func testGitCommitTimeoutReturnsItsReflogIdentifiedCommit() throws {
        let fixture = try makeGitFixture(label: "commit-timeout")
        defer {
            fixture.app.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try configureGitFixture(at: fixture.repository)
        let tracked = fixture.repository.appendingPathComponent("tracked.txt")
        try Data("before\n".utf8).write(to: tracked)
        _ = try runGit(["add", "tracked.txt"], cwd: fixture.repository)
        _ = try runGit(["commit", "--quiet", "-m", "Seed commit timeout"], cwd: fixture.repository)
        let headBefore = try runGit(["rev-parse", "HEAD"], cwd: fixture.repository).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("after\n".utf8).write(to: tracked)
        _ = try runGit(["add", "tracked.txt"], cwd: fixture.repository)

        let hook = fixture.repository.appendingPathComponent(".git/hooks/post-commit")
        try Data(
            """
            #!/bin/sh
            : > post-commit-timeout-ready
            while :; do sleep 1; done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let pack = GitToolPack(
            runner: ProcessRunner(
                terminationGraceSec: 0.05,
                forcedTerminationGraceSec: 0.2
            ),
            commandTimeoutSeconds: 2
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "git_commit",
            arguments: [
                "cwd": fixture.repository.path,
                "message": "Commit timeout reconciliation",
            ],
            context: nil,
            clientID: ClientID("git-commit-timeout"),
            app: fixture.app,
            cancellation: nil
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        let committed = try XCTUnwrap(result.payload["commit"] as? String)
        XCTAssertNotEqual(committed, headBefore)
        XCTAssertEqual(
            try runGit(["rev-parse", "HEAD"], cwd: fixture.repository).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines),
            committed
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.repository.appendingPathComponent("post-commit-timeout-ready").path
            )
        )
    }

    func testGitAddTimeoutReturnsOnlyWhenRequestedPathspecMatchesExpectedIndex() throws {
        let fixture = try makeGitFixture(label: "add-timeout")
        defer {
            fixture.app.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try configureGitFixture(at: fixture.repository)
        let tracked = fixture.repository.appendingPathComponent("tracked.txt")
        try Data("before\n".utf8).write(to: tracked)
        _ = try runGit(["add", "tracked.txt"], cwd: fixture.repository)
        _ = try runGit(["commit", "--quiet", "-m", "Seed add timeout"], cwd: fixture.repository)
        let hook = fixture.repository.appendingPathComponent(".git/hooks/post-index-change")
        try Data(
            """
            #!/bin/sh
            /usr/bin/git diff --cached --quiet -- tracked.txt && exit 0
            : > post-index-timeout-ready
            while :; do sleep 1; done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("after\n".utf8).write(to: tracked)
        let pack = GitToolPack(
            runner: ProcessRunner(
                terminationGraceSec: 0.05,
                forcedTerminationGraceSec: 0.2
            ),
            commandTimeoutSeconds: 2
        )

        let result = try XCTUnwrap(try pack.handle(
            name: "git_add",
            arguments: ["cwd": fixture.repository.path, "path": "tracked.txt"],
            context: nil,
            clientID: ClientID("git-add-timeout"),
            app: fixture.app,
            cancellation: nil
        ))

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["reconciled"] as? Bool, true)
        XCTAssertEqual(result.payload["pathspec"] as? String, "tracked.txt")
        XCTAssertEqual(
            try runGit(["show", ":tracked.txt"], cwd: fixture.repository).stdout,
            "after\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.repository.appendingPathComponent("post-index-timeout-ready").path
            )
        )
    }

    func testUnrelatedIndexMutationCannotReconcileCancelledGitAdd() throws {
        let fixture = try makeGitFixture(label: "add-pathspec-proof")
        defer {
            fixture.app.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try configureGitFixture(at: fixture.repository)
        let requested = fixture.repository.appendingPathComponent("requested.txt")
        let unrelated = fixture.repository.appendingPathComponent("unrelated.txt")
        try Data("before requested\n".utf8).write(to: requested)
        try Data("before unrelated\n".utf8).write(to: unrelated)
        _ = try runGit(["add", "."], cwd: fixture.repository)
        _ = try runGit(["commit", "--quiet", "-m", "Seed pathspec proof"], cwd: fixture.repository)
        let hook = fixture.repository.appendingPathComponent(".git/hooks/post-index-change")
        try Data(
            """
            #!/bin/sh
            [ -f pathspec-hook-active ] && exit 0
            : > pathspec-hook-active
            /usr/bin/git reset --quiet HEAD -- requested.txt
            /usr/bin/git add -- unrelated.txt
            : > pathspec-hook-ready
            while [ ! -f pathspec-hook-release ]; do sleep 0.05; done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("after requested\n".utf8).write(to: requested)
        try Data("after unrelated\n".utf8).write(to: unrelated)

        let cancellation = ToolCallCancellation(timeoutSeconds: 10)
        let outcome = GitCallOutcomeBox()
        let finished = expectation(description: "cancelled requested add")
        let pack = GitToolPack()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome.store(.success(try pack.handle(
                    name: "git_add",
                    arguments: ["cwd": fixture.repository.path, "path": "requested.txt"],
                    context: nil,
                    clientID: ClientID("git-add-pathspec-proof"),
                    app: fixture.app,
                    cancellation: cancellation
                )))
            } catch {
                outcome.store(.failure(error))
            }
            finished.fulfill()
        }
        let ready = fixture.repository.appendingPathComponent("pathspec-hook-ready")
        XCTAssertTrue(waitForFile(ready, timeout: 5))
        cancellation.cancel()
        wait(for: [finished], timeout: 5)
        try? Data().write(to: fixture.repository.appendingPathComponent("pathspec-hook-release"))

        switch try XCTUnwrap(outcome.load()) {
        case .success(let result):
            XCTFail("cancelled requested add was reported as \(String(describing: result))")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(
            try runGit(["diff", "--cached", "--name-only"], cwd: fixture.repository).stdout,
            "unrelated.txt\n"
        )
    }

    func testRepositoryMutationLockRejectsCancelledQueuedAdd() throws {
        let fixture = try makeGitFixture(label: "mutation-lock")
        defer {
            fixture.app.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try configureGitFixture(at: fixture.repository)
        let first = fixture.repository.appendingPathComponent("first.txt")
        let second = fixture.repository.appendingPathComponent("second.txt")
        try Data("before first\n".utf8).write(to: first)
        try Data("before second\n".utf8).write(to: second)
        _ = try runGit(["add", "."], cwd: fixture.repository)
        _ = try runGit(["commit", "--quiet", "-m", "Seed mutation lock"], cwd: fixture.repository)
        try Data("after first\n".utf8).write(to: first)
        try Data("after second\n".utf8).write(to: second)
        let hook = fixture.repository.appendingPathComponent(".git/hooks/post-index-change")
        try Data(
            """
            #!/bin/sh
            /usr/bin/git diff --cached --quiet -- first.txt && exit 0
            : > mutation-lock-ready
            while [ ! -f mutation-lock-release ]; do sleep 0.05; done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let firstOutcome = GitCallOutcomeBox()
        let firstFinished = expectation(description: "first add completes")
        let firstPack = GitToolPack()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                firstOutcome.store(.success(try firstPack.handle(
                    name: "git_add",
                    arguments: ["cwd": fixture.repository.path, "path": "first.txt"],
                    context: nil,
                    clientID: ClientID("git-first-serialized-add"),
                    app: fixture.app,
                    cancellation: ToolCallCancellation(timeoutSeconds: 10)
                )))
            } catch {
                firstOutcome.store(.failure(error))
            }
            firstFinished.fulfill()
        }
        XCTAssertTrue(
            waitForFile(fixture.repository.appendingPathComponent("mutation-lock-ready"), timeout: 5)
        )

        let secondCancellation = ToolCallCancellation(timeoutSeconds: 10)
        let secondOutcome = GitCallOutcomeBox()
        let secondFinished = expectation(description: "queued add is cancelled")
        let secondPack = GitToolPack()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                secondOutcome.store(.success(try secondPack.handle(
                    name: "git_add",
                    arguments: ["cwd": fixture.repository.path, "path": "second.txt"],
                    context: nil,
                    clientID: ClientID("git-second-serialized-add"),
                    app: fixture.app,
                    cancellation: secondCancellation
                )))
            } catch {
                secondOutcome.store(.failure(error))
            }
            secondFinished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        secondCancellation.cancel()
        wait(for: [secondFinished], timeout: 2)
        try Data().write(to: fixture.repository.appendingPathComponent("mutation-lock-release"))
        wait(for: [firstFinished], timeout: 5)

        switch try XCTUnwrap(secondOutcome.load()) {
        case .success(let result):
            XCTFail("queued add was reported as \(String(describing: result))")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        switch try XCTUnwrap(firstOutcome.load()) {
        case .success(let result):
            XCTAssertTrue(try XCTUnwrap(result).ok)
        case .failure(let error):
            XCTFail("first add failed: \(error)")
        }
        XCTAssertEqual(
            try runGit(["diff", "--cached", "--name-only"], cwd: fixture.repository).stdout,
            "first.txt\n"
        )
    }

    private func makeProjectFixture(label: String) throws -> (
        root: URL,
        project: URL,
        paths: AppPaths
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-committed-result-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = AppPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureLayout()
        return (root, project, paths)
    }

    private func makeGitFixture(label: String) throws -> (
        root: URL,
        repository: URL,
        app: ForgeApp
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-git-result-\(label)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        return (root, repository, app)
    }

    private func configureGitFixture(at repository: URL) throws {
        _ = try runGit(["init", "--quiet"], cwd: repository)
        _ = try runGit(["config", "user.name", "Forge Fixture"], cwd: repository)
        _ = try runGit(["config", "user.email", "fixture@forge.invalid"], cwd: repository)
        _ = try runGit(["config", "commit.gpgsign", "false"], cwd: repository)
    }

    @discardableResult
    private func runGit(_ arguments: [String], cwd: URL) throws -> ProcessResult {
        let result = try ProcessRunner().run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: cwd.path,
            timeoutSec: 10
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw NSError(
                domain: "CommittedResultRecoveryTests",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func makeMemoryFixture(label: String) throws -> (
        root: URL,
        project: URL,
        projectID: String,
        memory: ProjectMemoryService
    ) {
        let base = try makeProjectFixture(label: label)
        let memory = ProjectMemoryService(paths: base.paths)
        let initialized = try memory.initialize(path: base.project.path)
        return (
            base.root,
            base.project,
            try XCTUnwrap(initialized["project_id"] as? String),
            memory
        )
    }

    private func continuityV2Arguments(
        fixture: (root: URL, project: URL, projectID: String, memory: ProjectMemoryService),
        operationID: String,
        mode: ContinuityMode
    ) -> [String: Any] {
        [
            "project_id": fixture.projectID,
            "project_generation": 1,
            "run_id": UUID().uuidString.lowercased(),
            "operation_id": operationID,
            "handoff_id": UUID().uuidString.lowercased(),
            "continuity_mode": mode.rawValue,
            "predecessor_session_id": "predecessor",
            "provider_id": "lmstudio-local",
            "provider_response_id": "response-predecessor",
            "adapter_id": "forge.native-session-host",
            "model": "fixture/tool-model",
            "mission": "Return the already committed continuity outcome",
            "assignment_id": "FC-CONT-RESULT",
            "phase_id": "FC-CONT-RESULT",
            "work_item_id": "committed-result",
            "summary": "Avoid a throwing readback after durable mutation",
            "repository_root": fixture.project.path,
            "next_actions": ["Continue from the committed handoff"],
            "context_capacity": 32_768,
            "context_used": 27_000,
            "context_reserved": 4_096,
            "context_remaining": 1_672,
            "context_confidence": 1.0,
            "context_action": "rollover",
            "context_trigger": "rollover threshold crossed",
            "context_budget_source": "provider_exact",
            "bootstrap_nonce": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "idempotency_key": "committed-result-\(operationID)",
            "requested_by": "continuity.request_rollover",
            "reason": "committed result qualification",
        ]
    }

    private func makeHandoffV2(projectID: String) throws -> ContinuityHandoffV2 {
        try ContinuityHandoffV2(
            operationID: UUID().uuidString.lowercased(),
            project: [
                "project_id": projectID,
                "generation": 1,
                "display_name": "Committed Result Fixture",
                "repository_root": "/fixture",
                "branch": "repair/continuity",
                "commit": "1234567",
                "dirty_summary": [] as [String],
            ],
            run: [
                "run_id": UUID().uuidString.lowercased(),
                "continuity_mode": ContinuityMode.externalMCPCompatibility.rawValue,
                "assignment_id": "FC-CONT-RESULT",
            ],
            predecessorSession: [
                "session_id": "predecessor",
                "provider_id": "lmstudio-local",
                "provider_response_id": "response-predecessor",
                "adapter_id": "forge.native-session-host",
                "model": "fixture/tool-model",
            ],
            mission: "Reconcile the canonical committed continuity state",
            currentWork: [
                "phase_id": "FC-CONT-RESULT",
                "work_item_id": "projection-reconcile",
                "summary": "Treat SQLite as canonical after projection failure",
                "active_files": [] as [String],
            ],
            nextActions: [[
                "order": 0,
                "action": "Continue from the committed checkpoint",
                "command": "",
                "success_condition": "The prepared operation is returned",
                "replay_class": "idempotent",
            ]],
            contextBudget: [
                "capacity": 32_768,
                "used": 27_000,
                "reserved": 4_096,
                "remaining": 1_672,
                "source": "provider_exact",
                "confidence": 1.0,
                "action": "rollover",
                "trigger": "rollover threshold crossed",
            ],
            bootstrap: [
                "nonce": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "acknowledgement_contract_version": 2,
            ]
        ).validated()
    }

    private static func replaceDatabaseWithDirectory(
        memory: ProjectMemoryService,
        projectID: String,
        databaseURL: URL,
        backupURL: URL
    ) {
        memory.closeProject(projectID)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: backupURL)
        try? fileManager.moveItem(at: databaseURL, to: backupURL)
        try? fileManager.createDirectory(at: databaseURL, withIntermediateDirectories: false)
    }

    private func assertDatabaseWasReplaced(databaseURL: URL, backupURL: URL) throws {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }
}

private final class GitCallOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<ToolResult?, Error>?

    func store(_ outcome: Result<ToolResult?, Error>) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func load() -> Result<ToolResult?, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

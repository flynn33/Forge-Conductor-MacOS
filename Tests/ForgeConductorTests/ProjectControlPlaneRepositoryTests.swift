// ProjectControlPlaneRepositoryTests.swift
// Verifies durable project isolation, exact owner binding, and generation fencing.

import XCTest
@testable import ForgeConductorCore

final class ProjectControlPlaneRepositoryTests: XCTestCase {
    func testRegistrationRefreshesExactMetadataButRequiresRelinkForMovedRoot() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("registered-project", isDirectory: true)
            let first = try await repository.registerProject(
                projectID: projectID,
                displayName: "Initial Name",
                canonicalRoot: projectRoot,
                repositoryFingerprint: "first"
            )
            let refreshed = try await repository.registerProject(
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
                _ = try await repository.registerProject(
                    projectID: ProjectID(),
                    displayName: "Conflicting Project",
                    canonicalRoot: projectRoot
                )
            }

            let movedRoot = root.appendingPathComponent("moved-project", isDirectory: true)
            await assertContextError(code: "project_relink_required") {
                _ = try await repository.registerProject(
                    projectID: projectID,
                    displayName: "Moved",
                    canonicalRoot: movedRoot
                )
            }
        }
    }

    func testTwoProjectsRemainIsolatedAndOwnersAreUnique() async throws {
        try await withRepository { repository, root in
            let projectA = ProjectID()
            let projectB = ProjectID()
            let rootA = root.appendingPathComponent("project-a", isDirectory: true)
            let rootB = root.appendingPathComponent("project-b", isDirectory: true)
            _ = try await repository.registerProject(
                projectID: projectA,
                displayName: "Project A",
                canonicalRoot: rootA
            )
            _ = try await repository.registerProject(
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

    func testResetFencesStaleGenerationAndQuarantineIsBounded() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("reset-project", isDirectory: true)
            _ = try await repository.registerProject(
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
            _ = try await repository.registerProject(
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
            _ = try await repository.registerProject(
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

    func testInvalidGenerationAndAuthorizationScopeAreRejectedBeforePersistence() async throws {
        try await withRepository { repository, root in
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("validation-project", isDirectory: true)
            _ = try await repository.registerProject(
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

    private func withRepository(
        _ body: (ProjectControlPlaneRepository, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-control-plane-\(UUID().uuidString)", isDirectory: true)
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3"),
            clock: FixedClock(Date(timeIntervalSince1970: 1_000))
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

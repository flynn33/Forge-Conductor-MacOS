import XCTest
@testable import ForgeConductorCore

final class ProjectInstructionQueueTests: XCTestCase {
    func testBuiltInCompletionGateRequiresExactSuccessfulDurableTools() throws {
        let projectID = ProjectID()
        let runID = RunID()
        let run = AutonomousRunRecord(
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            assignmentID: "package-fixture",
            mission: "Fixture mission",
            state: .validatingCompletion,
            continuityMode: .managedAutonomous,
            providerID: "lmstudio",
            modelKey: "fixture",
            activeSessionID: nil,
            activeOperationID: nil,
            specification: AutonomousRunSpecification(
                allowedTools: ["fs_read"],
                completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
            ),
            completionRequestJSON: "{}",
            lastErrorCode: nil,
            lastErrorSummary: nil,
            retryAt: nil,
            continuationPending: false,
            revision: 4,
            createdAt: "2027-01-15T08:00:00Z",
            updatedAt: "2027-01-15T08:00:01Z"
        )
        let successful = toolInvocation(
            runID: runID,
            projectID: projectID,
            result: #"{"is_error":false,"ok":true,"payload":{"ok":true}}"#
        )
        XCTAssertTrue(
            ProjectInstructionCompletionGate.result(run: run, invocations: [successful]).passed
        )

        let failed = toolInvocation(
            runID: runID,
            projectID: projectID,
            result: #"{"is_error":true,"ok":false,"payload":{"ok":false}}"#
        )
        XCTAssertFalse(
            ProjectInstructionCompletionGate.result(run: run, invocations: [failed]).passed
        )
        XCTAssertFalse(
            ProjectInstructionCompletionGate.result(run: run, invocations: []).passed
        )
    }

    func testPlainDocumentImportPublishesImmutableProjectScopedSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("First.md")
        try "Inspect the repository and repair the first defect.".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )

        XCTAssertEqual(snapshot.packages.count, 1)
        let package = try XCTUnwrap(snapshot.packages.first)
        XCTAssertEqual(package.projectID, fixture.projectID)
        XCTAssertEqual(package.projectGeneration, .initial)
        XCTAssertEqual(package.state, .queued)
        XCTAssertEqual(package.completionGates, [ProjectInstructionQueueStore.builtInCompletionGate])
        XCTAssertEqual(package.sourcePath, source.path)
        XCTAssertFalse(package.allowedTools.isEmpty)

        try "Changed after import".write(to: source, atomically: true, encoding: .utf8)
        let accepted = fixture.paths.instructionPackageStoreDir
            .appendingPathComponent(package.contentSHA256)
            .appendingPathComponent("First.md")
        XCTAssertEqual(
            try String(contentsOf: accepted, encoding: .utf8),
            "Inspect the repository and repair the first defect."
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: accepted.path)[.posixPermissions] as? NSNumber,
            NSNumber(value: Int16(0o400))
        )
        let references = try fixture.store.documentReferences(
            contentSHA256: package.contentSHA256
        )
        XCTAssertEqual(references.count, 1)
        XCTAssertTrue(references[0].reference.hasSuffix("/First.md"))
        XCTAssertEqual(
            references[0].sha256,
            JSONSupport.sha256Hex(Data("Inspect the repository and repair the first defect.".utf8))
        )
    }

    func testManifestDirectoryReordersAndSurvivesRestart() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try makeManifestPackage(
            root: fixture.external.appendingPathComponent("one", isDirectory: true),
            packageID: "one",
            projectID: fixture.projectID,
            mission: "Complete package one."
        )
        let second = try makeManifestPackage(
            root: fixture.external.appendingPathComponent("two", isDirectory: true),
            packageID: "two",
            projectID: fixture.projectID,
            mission: "Complete package two."
        )
        var snapshot = try fixture.store.importPackage(
            sourceURL: first,
            projectID: fixture.projectID,
            generation: .initial
        )
        snapshot = try fixture.store.importPackage(
            sourceURL: second,
            projectID: fixture.projectID,
            generation: .initial
        )
        let reversed = snapshot.packages.reversed().map(\.id)
        snapshot = try fixture.store.reorder(
            projectID: fixture.projectID,
            generation: .initial,
            packageIDs: reversed,
            expectedRevision: snapshot.revision
        )
        XCTAssertEqual(snapshot.packages.map(\.packageID), ["two", "one"])

        let reopened = try ProjectInstructionQueueStore(paths: fixture.paths, clock: fixture.clock)
        let persisted = try reopened.snapshot(projectID: fixture.projectID, generation: .initial)
        XCTAssertEqual(persisted.packages.map(\.packageID), ["two", "one"])
        XCTAssertEqual(persisted.revision, snapshot.revision)
    }

    func testQueueAdvancesOnlyAfterCompletedRunAndStopsAtFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in ["one", "two"] {
            let source = fixture.external.appendingPathComponent("\(name).md")
            try "Complete \(name).".write(to: source, atomically: true, encoding: .utf8)
            _ = try fixture.store.importPackage(
                sourceURL: source,
                projectID: fixture.projectID,
                generation: .initial
            )
        }

        _ = try fixture.store.start(projectID: fixture.projectID, generation: .initial)
        let first = try XCTUnwrap(fixture.store.nextRunnable())
        let firstRun = RunID()
        _ = try fixture.store.markStarted(packageID: first.id, runID: firstRun)
        XCTAssertNil(fixture.store.nextRunnable())
        _ = try fixture.store.reconcile(
            packageID: first.id,
            runID: firstRun,
            runState: .completed
        )

        let second = try XCTUnwrap(fixture.store.nextRunnable())
        XCTAssertNotEqual(second.id, first.id)
        let secondRun = RunID()
        _ = try fixture.store.markStarted(packageID: second.id, runID: secondRun)
        _ = try fixture.store.reconcile(
            packageID: second.id,
            runID: secondRun,
            runState: .failedTerminal,
            error: "fixture failure"
        )
        let final = try fixture.store.snapshot(projectID: fixture.projectID, generation: .initial)
        XCTAssertFalse(final.running)
        XCTAssertEqual(final.packages.map(\.state), [.completed, .failed])
        XCTAssertEqual(final.packages.last?.lastError, "fixture failure")
    }

    func testNewProjectGenerationHasIndependentQueueAndProjectRemovalClearsIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.external.appendingPathComponent("first.md")
        let second = fixture.external.appendingPathComponent("second.md")
        try "First generation work.".write(to: first, atomically: true, encoding: .utf8)
        try "Second generation work.".write(to: second, atomically: true, encoding: .utf8)
        _ = try fixture.store.importPackage(
            sourceURL: first,
            projectID: fixture.projectID,
            generation: .initial
        )
        _ = try fixture.store.fenceProject(
            projectID: fixture.projectID,
            generation: .initial,
            reason: "generation reset"
        )
        let generationTwo = ProjectGeneration(2)
        let current = try fixture.store.importPackage(
            sourceURL: second,
            projectID: fixture.projectID,
            generation: generationTwo
        )

        XCTAssertEqual(current.packages.map(\.displayName), ["second"])
        _ = try fixture.store.start(
            projectID: fixture.projectID,
            generation: generationTwo
        )
        XCTAssertEqual(fixture.store.nextRunnable()?.projectGeneration, generationTwo)
        XCTAssertEqual(try fixture.store.removeProject(projectID: fixture.projectID), 2)
        let empty = try fixture.store.snapshot(
            projectID: fixture.projectID,
            generation: generationTwo
        )
        XCTAssertTrue(empty.packages.isEmpty)
        XCTAssertFalse(empty.running)
    }

    func testManifestRejectsProjectMismatchAndEntryTraversal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let packageRoot = fixture.external.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schema_version": 1,
            "package_id": "invalid",
            "version": "1",
            "mission": "Must not import.",
            "project_id": UUID().uuidString.lowercased(),
            "entry_documents": ["../outside.md"],
            "requested_capabilities": ["fs_read"],
            "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
            "resource_policy": ["profile": "project-default"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: packageRoot.appendingPathComponent("forge-package.json"))

        XCTAssertThrowsError(
            try fixture.store.importPackage(
                sourceURL: packageRoot,
                projectID: fixture.projectID,
                generation: .initial
            )
        ) { error in
            guard case ProjectInstructionQueueError.manifestInvalid = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeFixture() throws -> (
        root: URL,
        external: URL,
        paths: AppPaths,
        projectID: ProjectID,
        clock: FixedClock,
        store: ProjectInstructionQueueStore
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-instruction-queue-\(UUID().uuidString)", isDirectory: true)
        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let paths = AppPaths(home: root.appendingPathComponent("home", isDirectory: true))
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        return (
            root, external, paths, ProjectID(), clock,
            try ProjectInstructionQueueStore(paths: paths, clock: clock)
        )
    }

    private func makeManifestPackage(
        root: URL,
        packageID: String,
        projectID: ProjectID,
        mission: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Follow these package details.".write(
            to: root.appendingPathComponent("instructions.md"),
            atomically: true,
            encoding: .utf8
        )
        let manifest: [String: Any] = [
            "schema_version": 1,
            "package_id": packageID,
            "version": "1.0",
            "mission": mission,
            "project_id": projectID.description,
            "entry_documents": ["instructions.md"],
            "requested_capabilities": ["fs_read", "fs_edit", "shell_exec"],
            "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
            "resource_policy": ["profile": "project-default"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("forge-package.json"))
        return root
    }

    private func toolInvocation(
        runID: RunID,
        projectID: ProjectID,
        result: String
    ) -> ToolInvocationRecord {
        ToolInvocationRecord(
            invocationID: UUID(),
            turnID: UUID(),
            runID: runID,
            sessionID: "fixture-session",
            projectID: projectID,
            projectGeneration: .initial,
            providerCallID: UUID().uuidString.lowercased(),
            toolName: "fs_read",
            replayClass: .readOnly,
            idempotencyKey: nil,
            argumentsSHA256: String(repeating: "a", count: 64),
            reconciliationDescriptor: nil,
            state: .completed,
            resultSHA256: JSONSupport.sha256Hex(result),
            resultSummary: result,
            lastErrorCode: nil,
            lastErrorSummary: nil,
            createdAt: "2027-01-15T08:00:00Z",
            updatedAt: "2027-01-15T08:00:01Z"
        )
    }
}

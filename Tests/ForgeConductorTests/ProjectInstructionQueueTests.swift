import XCTest
import AppKit
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
        var successfulAccumulator = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        try successfulAccumulator.consume([successful])
        XCTAssertTrue(successfulAccumulator.result().passed)

        let failed = toolInvocation(
            runID: runID,
            projectID: projectID,
            result: #"{"is_error":true,"ok":false,"payload":{"ok":false}}"#
        )
        var failedAccumulator = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        try failedAccumulator.consume([failed])
        XCTAssertFalse(failedAccumulator.result().passed)
        XCTAssertFalse(ProjectInstructionCompletionGate.EvidenceAccumulator(run: run).result().passed)
    }

    func testOutcomeAwareCompletionSupersedesFailedBuildAndRejectsUnrelatedRead() throws {
        let projectID = ProjectID()
        let runID = RunID()
        let digest = String(repeating: "c", count: 64)
        let plan = try completionPlan(
            projectID: projectID,
            digest: digest,
            kinds: [.artifactRegistered, .projectBuild, .projectTests, .noRelevantUnresolvedSideEffect]
        )
        let run = completionRun(runID: runID, projectID: projectID, digest: digest, plan: plan)
        let failedBuild = toolInvocation(
            runID: runID,
            projectID: projectID,
            toolName: "shell_exec",
            result: try shellResult(command: "swift build", ok: false),
            createdAt: "2027-01-15T08:00:00Z"
        )
        let passingBuild = toolInvocation(
            runID: runID,
            projectID: projectID,
            toolName: "shell_exec",
            result: try shellResult(command: "swift build", ok: true),
            createdAt: "2027-01-15T08:00:01Z"
        )
        let passingTests = toolInvocation(
            runID: runID,
            projectID: projectID,
            toolName: "shell_exec",
            result: try shellResult(command: "swift test --filter FixtureTests", ok: true),
            createdAt: "2027-01-15T08:00:02Z"
        )
        var recovered = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        try recovered.consume([failedBuild, passingBuild, passingTests])
        XCTAssertTrue(recovered.result().passed)
        XCTAssertEqual(recovered.result().evidenceReferences.count, 2)

        let laterFailedBuild = toolInvocation(
            runID: runID,
            projectID: projectID,
            toolName: "shell_exec",
            result: try shellResult(command: "swift build", ok: false),
            createdAt: "2027-01-15T08:00:03Z"
        )
        try recovered.consume([laterFailedBuild])
        XCTAssertFalse(recovered.result().passed)

        let read = toolInvocation(
            runID: runID,
            projectID: projectID,
            result: #"{"is_error":false,"ok":true,"payload":{"ok":true}}"#
        )
        var unrelated = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        try unrelated.consume([read])
        XCTAssertFalse(unrelated.result().passed)
        XCTAssertTrue(unrelated.result().summary.contains("project-build"))
    }

    func testReadOnlyCompletionPagesMoreThan256RecordsAndRejectsWrongScope() throws {
        let projectID = ProjectID()
        let runID = RunID()
        let digest = String(repeating: "e", count: 64)
        let plan = try completionPlan(
            projectID: projectID,
            digest: digest,
            kinds: [.artifactRegistered, .readOnlyReportDelivered, .noRelevantUnresolvedSideEffect]
        )
        let run = completionRun(runID: runID, projectID: projectID, digest: digest, plan: plan)
        let records = (0..<300).map { index in
            toolInvocation(
                runID: runID,
                projectID: projectID,
                result: #"{"is_error":false,"ok":true,"payload":{"ok":true}}"#,
                createdAt: String(format: "2027-01-15T08:%02d:%02dZ", index / 60, index % 60)
            )
        }
        var paged = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        for offset in stride(from: 0, to: records.count, by: 128) {
            try paged.consume(Array(records[offset..<min(offset + 128, records.count)]))
        }
        XCTAssertTrue(paged.result().passed)
        XCTAssertTrue(paged.result().summary.contains("300 paged evidence records"))

        var wrongScope = ProjectInstructionCompletionGate.EvidenceAccumulator(run: run)
        try wrongScope.consume([
            toolInvocation(
                runID: runID,
                projectID: ProjectID(),
                result: #"{"is_error":false,"ok":true,"payload":{"ok":true}}"#
            ),
        ])
        XCTAssertFalse(wrongScope.result().passed)
        XCTAssertTrue(wrongScope.result().summary.contains("different project"))

        let staleSourceRun = completionRun(
            runID: runID,
            projectID: projectID,
            digest: String(repeating: "f", count: 64),
            plan: plan
        )
        var staleSource = ProjectInstructionCompletionGate.EvidenceAccumulator(run: staleSourceRun)
        try staleSource.consume([records[0]])
        XCTAssertFalse(staleSource.result().passed)
        XCTAssertTrue(staleSource.result().summary.contains("artifact-registered"))

        let tamperedPlan = AutomaticCompletionPlan(
            planID: UUID(),
            projectID: plan.projectID,
            projectGeneration: plan.projectGeneration,
            instructionArtifactSHA256: plan.instructionArtifactSHA256,
            obligations: plan.obligations,
            source: plan.source,
            revision: plan.revision
        )
        let tamperedRun = completionRun(
            runID: runID,
            projectID: projectID,
            digest: digest,
            plan: tamperedPlan
        )
        var tampered = ProjectInstructionCompletionGate.EvidenceAccumulator(run: tamperedRun)
        try tampered.consume([records[0]])
        XCTAssertFalse(tampered.result().passed)
        XCTAssertTrue(tampered.result().summary.contains("plan revision"))
    }

    func testAutomaticCompletionPlanIsStableAndDistinguishesReadOnlyFromRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-completion-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("// swift-tools-version: 6.2\n".utf8).write(
            to: root.appendingPathComponent("Package.swift"),
            options: .atomic
        )
        let projectID = ProjectID()
        let digest = String(repeating: "d", count: 64)

        let readOnlyInput = AutomaticCompletionPlanResolver.Input(
            projectID: projectID,
            projectGeneration: .initial,
            projectRoot: root,
            instructionArtifactSHA256: [digest],
            instructionText: "Audit the current implementation and deliver a read-only report.",
            documentCount: 1,
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        let first = try AutomaticCompletionPlanResolver.resolve(readOnlyInput)
        let replay = try AutomaticCompletionPlanResolver.resolve(readOnlyInput)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.planID, replay.planID)
        XCTAssertEqual(first.instructionArtifactSHA256, [digest])
        XCTAssertEqual(
            Set(first.obligations.map(\.kind)),
            [.artifactRegistered, .readOnlyReportDelivered, .noRelevantUnresolvedSideEffect]
        )
        XCTAssertFalse(first.obligations.contains { $0.kind == .projectBuild })
        XCTAssertFalse(first.obligations.contains { $0.kind == .projectTests })

        let repair = try AutomaticCompletionPlanResolver.resolve(.init(
            projectID: projectID,
            projectGeneration: .initial,
            projectRoot: root,
            instructionArtifactSHA256: [digest],
            instructionText: "Repair the Swift defect and run the affected tests.",
            documentCount: 1,
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate, "org.example.native"]
        ))
        XCTAssertNotEqual(repair.planID, first.planID)
        XCTAssertEqual(repair.source, .automaticWithCustomPolicy)
        XCTAssertTrue(repair.obligations.contains { $0.kind == .projectBuild })
        XCTAssertTrue(repair.obligations.contains { $0.kind == .projectTests })
        XCTAssertTrue(repair.obligations.contains {
            $0.kind == .customNativeGate && $0.customGateID == "org.example.native"
        })
    }

    func testLegacyRunAndValidationPlanDecodeWithoutAutomaticCompletionPlan() throws {
        let specification = AutonomousRunSpecification(
            allowedTools: ["fs_read"],
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        var specificationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(specification)) as? [String: Any]
        )
        specificationObject.removeValue(forKey: "completion_plan")
        let legacySpecification = try JSONDecoder().decode(
            AutonomousRunSpecification.self,
            from: JSONSerialization.data(withJSONObject: specificationObject, options: [.sortedKeys])
        )
        XCTAssertNil(legacySpecification.completionPlan)
        XCTAssertEqual(legacySpecification.allowedTools, ["fs_read"])

        let validation = ManagerPreparedRunValidationPlan(
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        var validationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(validation)) as? [String: Any]
        )
        validationObject.removeValue(forKey: "automatic_plan")
        let legacyValidation = try JSONDecoder().decode(
            ManagerPreparedRunValidationPlan.self,
            from: JSONSerialization.data(withJSONObject: validationObject, options: [.sortedKeys])
        )
        XCTAssertNil(legacyValidation.automaticPlan)
        XCTAssertEqual(legacyValidation.mode, "manager_completion_gates")
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
            .appendingPathComponent("originals")
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
        XCTAssertTrue(references[0].reference.hasSuffix("/.forge/canonical/document-000001.txt"))
        XCTAssertEqual(
            references[0].sha256,
            JSONSupport.sha256Hex(Data("Inspect the repository and repair the first defect.".utf8))
        )
    }

    func testLargeMissionBoundariesUseArtifactBackedBootstrap() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for count in [1, 32_767, 32_768, 32_769, 1_100_000] {
            let source = fixture.external.appendingPathComponent("instructions-\(count).data")
            try Data(repeating: 0x61, count: count).write(to: source)
            let snapshot = try fixture.store.importPackage(
                sourceURL: source,
                projectID: fixture.projectID,
                generation: .initial
            )
            let package = try XCTUnwrap(snapshot.packages.last)
            XCTAssertLessThanOrEqual(package.mission.utf8.count, ProjectInstructionQueueStore.maximumMissionBytes)
            XCTAssertEqual(package.instructionByteCount, count)
            XCTAssertEqual(package.unresolvedDocumentCount, 0)
            XCTAssertTrue(package.allowedTools.contains("instruction_read"))
        }
    }

    func testDirectRunArtifactIsDurableRunBoundAndDoesNotEnterQueue() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("pasted-task.txt")
        let instructions = String(repeating: "Preserve every requirement.\n", count: 80_000)
        try instructions.write(to: source, atomically: true, encoding: .utf8)
        let runID = RunID()

        let imported = try fixture.store.importRunArtifact(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial,
            runID: runID
        )
        XCTAssertGreaterThan(imported.instructionByteCount, 1_048_576)
        XCTAssertLessThanOrEqual(
            imported.mission.utf8.count,
            ProjectInstructionQueueStore.maximumMissionBytes
        )
        XCTAssertEqual(imported.unresolvedDocumentCount, 0)
        XCTAssertTrue(try fixture.store.snapshot(
            projectID: fixture.projectID,
            generation: .initial
        ).packages.isEmpty)

        let reopened = try ProjectInstructionQueueStore(paths: fixture.paths, clock: fixture.clock)
        XCTAssertEqual(try reopened.runArtifact(
            contentSHA256: imported.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: runID
        ), imported)
        XCTAssertThrowsError(try reopened.runArtifact(
            contentSHA256: imported.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: RunID()
        ))
        XCTAssertThrowsError(try reopened.catalogPage(
            contentSHA256: imported.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: RunID(),
            cursor: 0,
            limit: 10
        ))
        let catalog = try reopened.catalogPage(
            contentSHA256: imported.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: runID,
            cursor: 0,
            limit: 10
        )
        XCTAssertEqual(catalog.totalDocuments, 1)
        XCTAssertEqual(
            try reopened.importRunArtifact(
                sourceURL: source,
                projectID: fixture.projectID,
                generation: .initial,
                runID: runID
            ),
            imported
        )
    }

    func testSelectedPackagesBindByImmutableHashAndComposeInVisibleOrder() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = fixture.external.appendingPathComponent("First.md")
        let secondSource = fixture.external.appendingPathComponent("Second.md")
        try "First selected requirement.".write(
            to: firstSource, atomically: true, encoding: .utf8
        )
        try "Second selected requirement.".write(
            to: secondSource, atomically: true, encoding: .utf8
        )
        var queue = try fixture.store.importPackage(
            sourceURL: firstSource,
            projectID: fixture.projectID,
            generation: .initial
        )
        queue = try fixture.store.importPackage(
            sourceURL: secondSource,
            projectID: fixture.projectID,
            generation: .initial
        )
        let first = try XCTUnwrap(queue.packages.first)
        let second = try XCTUnwrap(queue.packages.last)
        try FileManager.default.removeItem(at: firstSource)
        try FileManager.default.removeItem(at: secondSource)

        let singleRunID = RunID()
        let single = try fixture.store.assembleRunArtifact(
            sourceURL: nil,
            packageIDs: [first.id],
            projectID: fixture.projectID,
            generation: .initial,
            runID: singleRunID
        )
        XCTAssertEqual(single.contentSHA256, first.contentSHA256)
        XCTAssertEqual(single.documentCount, first.documentCount)

        let orderedRunID = RunID()
        let ordered = try fixture.store.assembleRunArtifact(
            sourceURL: nil,
            packageIDs: [second.id, first.id],
            projectID: fixture.projectID,
            generation: .initial,
            runID: orderedRunID
        )
        XCTAssertNotEqual(ordered.contentSHA256, first.contentSHA256)
        XCTAssertNotEqual(ordered.contentSHA256, second.contentSHA256)
        XCTAssertEqual(ordered.documentCount, 2)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: ordered.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: orderedRunID,
            cursor: 0,
            limit: 10
        )
        XCTAssertEqual(catalog.totalDocuments, 2)
        XCTAssertTrue(catalog.documents[0]["source_path"]?.contains("Second") == true)
        XCTAssertTrue(catalog.documents[1]["source_path"]?.contains("First") == true)
        XCTAssertEqual(
            try fixture.store.assembleRunArtifact(
                sourceURL: nil,
                packageIDs: [second.id, first.id],
                projectID: fixture.projectID,
                generation: .initial,
                runID: orderedRunID
            ),
            ordered
        )
        XCTAssertThrowsError(try fixture.store.assembleRunArtifact(
            sourceURL: nil,
            packageIDs: [first.id, second.id],
            projectID: fixture.projectID,
            generation: .initial,
            runID: orderedRunID
        ))
    }

    func testHiddenAndLargeDirectoryInventoryExceedsOldLimits() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.external.appendingPathComponent("large-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = Data(repeating: 0x78, count: 130_000)
        for index in 0..<66 {
            let name = index == 65 ? ".hidden-policy.yaml" : String(format: "item-%03d.json", index)
            try body.write(to: directory.appendingPathComponent(name))
        }

        let snapshot = try fixture.store.importPackage(
            sourceURL: directory,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(snapshot.packages.first)
        XCTAssertEqual(package.documentCount, 66)
        XCTAssertGreaterThan(package.instructionByteCount ?? 0, 8 * 1_048_576)
        let page = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 128
        )
        XCTAssertEqual(page.totalDocuments, 66)
        XCTAssertTrue(page.documents.contains { $0["source_path"] == ".hidden-policy.yaml" })
    }

    func testUTF16CanonicalDeliveryReassemblesExactlyAtScalarBoundaries() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("policy.unknown")
        let expected = "Global rule: 🛡️ preserve every résumé.\nLate acceptance: 完了。"
        var bytes = Data([0xFF, 0xFE])
        bytes.append(expected.data(using: .utf16LittleEndian)!)
        try bytes.write(to: source)
        let snapshot = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(snapshot.packages.first)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 10
        )
        let documentID = try XCTUnwrap(catalog.documents.first?["id"])
        var offset = 0
        var reconstructed = ""
        repeat {
            let page = try fixture.store.readDocument(
                contentSHA256: package.contentSHA256,
                documentID: documentID,
                projectID: fixture.projectID,
                generation: .initial,
                runID: nil,
                byteOffset: offset,
                maximumBytes: 7
            )
            reconstructed += page.content
            guard let next = page.nextByteOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(reconstructed, expected)
    }

    func testOpaqueBinaryIsRetainedUnresolvedAndCannotStart() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("opaque.bin")
        let bytes = Data([0x00, 0xFF, 0x01, 0x80])
        try bytes.write(to: source)
        let snapshot = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(snapshot.packages.first)
        XCTAssertEqual(package.unresolvedDocumentCount, 1)
        let retained = fixture.paths.instructionPackageStoreDir
            .appendingPathComponent(package.contentSHA256)
            .appendingPathComponent("originals")
            .appendingPathComponent("opaque.bin")
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
        XCTAssertThrowsError(
            try fixture.store.start(projectID: fixture.projectID, generation: .initial)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("unconverted"))
        }
    }

    func testNativeRichDocumentAdaptersPreserveOriginalsAndConvertText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.external.appendingPathComponent("rich", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rtfText = NSAttributedString(string: "RTF instruction")
        try rtfText.data(
            from: NSRange(location: 0, length: rtfText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ).write(to: directory.appendingPathComponent("policy.rtf"))
        try Data("<html><body><p>HTML instruction</p></body></html>".utf8)
            .write(to: directory.appendingPathComponent("policy.html"))
        let docxText = NSAttributedString(string: "DOCX instruction")
        try docxText.data(
            from: NSRange(location: 0, length: docxText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ).write(to: directory.appendingPathComponent("policy.docx"))

        let imported = try fixture.store.importPackage(
            sourceURL: directory,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(imported.packages.first)
        XCTAssertEqual(package.documentCount, 3)
        XCTAssertEqual(package.unresolvedDocumentCount, 0)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 10
        )
        XCTAssertEqual(Set(catalog.documents.compactMap { $0["status"] }), ["converted_instruction"])
        for document in catalog.documents {
            let page = try fixture.store.readDocument(
                contentSHA256: package.contentSHA256,
                documentID: try XCTUnwrap(document["id"]),
                projectID: fixture.projectID,
                generation: .initial,
                runID: nil,
                byteOffset: 0,
                maximumBytes: 4_096
            )
            XCTAssertTrue(page.content.contains("instruction"))
        }
    }

    func testMalformedPDFIsRetainedWithActionableUnresolvedStatus() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7\nnot-a-pdf".utf8).write(to: source)
        let imported = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(imported.packages.first)
        XCTAssertEqual(package.unresolvedDocumentCount, 1)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 10
        )
        XCTAssertEqual(catalog.documents.first?["status"], "unresolved_conversion")
        XCTAssertTrue(catalog.documents.first?["detail"]?.contains("encrypted or malformed") == true)
    }

    func testZIPImportInventoriesHiddenAndNativeDocumentsWithoutExecutingAssets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceRoot = fixture.external.appendingPathComponent("zip-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try "Late global rule".write(
            to: sourceRoot.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8
        )
        try "hidden: required".write(
            to: sourceRoot.appendingPathComponent(".policy.yaml"), atomically: true, encoding: .utf8
        )
        let rtf = NSAttributedString(string: "RTF archive instruction")
        try rtf.data(
            from: NSRange(location: 0, length: rtf.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ).write(to: sourceRoot.appendingPathComponent("policy.rtf"))
        let archive = fixture.external.appendingPathComponent("instructions.zip")
        try makeZIP(sourceRoot: sourceRoot, destination: archive)

        let imported = try fixture.store.importPackage(
            sourceURL: archive,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(imported.packages.first)
        XCTAssertEqual(package.unresolvedDocumentCount, 0)
        XCTAssertGreaterThanOrEqual(package.documentCount ?? 0, 4)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 128
        )
        XCTAssertTrue(catalog.documents.contains { $0["source_path"]?.hasSuffix("/.policy.yaml") == true })
        XCTAssertTrue(catalog.documents.contains { $0["source_path"] == "instructions.zip" })
        XCTAssertEqual(catalog.documents.first { $0["source_path"] == "instructions.zip" }?["status"], "retained_attachment")
    }

    func testZIPInspectionRejectsTraversalEncryptionLinksAndExpansionBombs() throws {
        var commented = minimalZIP(path: "commented.txt")
        let commentLengthOffset = commented.count - 2
        commented[commentLengthOffset] = 30
        commented[commentLengthOffset + 1] = 0
        var comment = Data(repeating: 0, count: 30)
        comment[0] = 0x50
        comment[1] = 0x4B
        comment[2] = 0x05
        comment[3] = 0x06
        commented.append(comment)
        XCTAssertEqual(try SafeZIPArchive.inspect(commented).map(\.path), ["commented.txt"])

        XCTAssertThrowsError(try SafeZIPArchive.inspect(minimalZIP(path: "../escape.txt"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsafe path"))
        }
        XCTAssertThrowsError(try SafeZIPArchive.inspect(minimalZIP(path: "secret.txt", flags: 1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("encrypted"))
        }
        XCTAssertThrowsError(try SafeZIPArchive.inspect(minimalZIP(
            path: "bomb.txt", compressedBytes: 1, uncompressedBytes: 100 * 1_048_576
        ))) { error in
            XCTAssertTrue(error.localizedDescription.contains("expansion ratio"))
        }

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceRoot = fixture.external.appendingPathComponent("link-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let outside = fixture.external.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sourceRoot.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )
        let archive = fixture.external.appendingPathComponent("linked.zip")
        try makeZIP(sourceRoot: sourceRoot, destination: archive)
        XCTAssertThrowsError(try fixture.store.importPackage(
            sourceURL: archive,
            projectID: fixture.projectID,
            generation: .initial
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("link or unsupported"))
        }
    }

    func testNestedZIPIsRetainedAndReportedWithoutRecursiveExpansion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let innerRoot = fixture.external.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: innerRoot, withIntermediateDirectories: true)
        try "nested instruction".write(
            to: innerRoot.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8
        )
        let innerZIP = fixture.external.appendingPathComponent("inner.zip")
        try makeZIP(sourceRoot: innerRoot, destination: innerZIP)
        let outerRoot = fixture.external.appendingPathComponent("outer", isDirectory: true)
        try FileManager.default.createDirectory(at: outerRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: innerZIP, to: outerRoot.appendingPathComponent("inner.zip"))
        try "outer instruction".write(
            to: outerRoot.appendingPathComponent("outer.txt"), atomically: true, encoding: .utf8
        )
        let outerZIP = fixture.external.appendingPathComponent("outer.zip")
        try makeZIP(sourceRoot: outerRoot, destination: outerZIP)
        let imported = try fixture.store.importPackage(
            sourceURL: outerZIP,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(imported.packages.first)
        XCTAssertEqual(package.unresolvedDocumentCount, 1)
        let catalog = try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: nil,
            cursor: 0,
            limit: 128
        )
        XCTAssertTrue(catalog.documents.contains {
            $0["detail"]?.contains("not recursively expanded") == true
        })
    }

    func testEmptyAndWhitespaceSourcesReportNoInstructions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (name, contents) in [("empty.txt", ""), ("blank.txt", " \n\t ")] {
            let source = fixture.external.appendingPathComponent(name)
            try contents.write(to: source, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try fixture.store.importPackage(
                sourceURL: source,
                projectID: fixture.projectID,
                generation: .initial
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("No non-whitespace instructions"))
            }
        }
    }

    func testArtifactAccessIsProjectGenerationAndRunBound() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("scoped.txt")
        try "Scoped instruction".write(to: source, atomically: true, encoding: .utf8)
        let imported = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )
        let package = try XCTUnwrap(imported.packages.first)
        _ = try fixture.store.start(projectID: fixture.projectID, generation: .initial)
        let runID = RunID()
        _ = try fixture.store.markStarted(packageID: package.id, runID: runID)

        XCTAssertNoThrow(try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: runID,
            cursor: 0,
            limit: 1
        ))
        XCTAssertThrowsError(try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: ProjectID(),
            generation: .initial,
            runID: runID,
            cursor: 0,
            limit: 1
        ))
        XCTAssertThrowsError(try fixture.store.catalogPage(
            contentSHA256: package.contentSHA256,
            projectID: fixture.projectID,
            generation: .initial,
            runID: RunID(),
            cursor: 0,
            limit: 1
        ))
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

    func testLegacyQueueMetadataMigratesWithoutLosingPackageIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.external.appendingPathComponent("legacy.txt")
        try "Preserve this legacy package.".write(to: source, atomically: true, encoding: .utf8)
        let imported = try fixture.store.importPackage(
            sourceURL: source,
            projectID: fixture.projectID,
            generation: .initial
        )
        let expected = try XCTUnwrap(imported.packages.first)
        let data = try Data(contentsOf: fixture.paths.instructionPackageQueue)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["schema_version"] = 1
        var packages = try XCTUnwrap(root["packages"] as? [[String: Any]])
        packages[0].removeValue(forKey: "document_count")
        packages[0].removeValue(forKey: "instruction_byte_count")
        packages[0].removeValue(forKey: "unresolved_document_count")
        root["packages"] = packages
        try OwnerOnlyAtomicFile.write(
            try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            to: fixture.paths.instructionPackageQueue
        )

        let reopened = try ProjectInstructionQueueStore(paths: fixture.paths, clock: fixture.clock)
        let migrated = try reopened.snapshot(projectID: fixture.projectID, generation: .initial)
        XCTAssertEqual(migrated.packages.first?.id, expected.id)
        XCTAssertEqual(migrated.packages.first?.contentSHA256, expected.contentSHA256)
        let migratedRoot = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.instructionPackageQueue)
        ) as? [String: Any])
        XCTAssertEqual(migratedRoot["schema_version"] as? Int, ProjectInstructionQueueStore.schemaVersion)
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

    private func makeZIP(sourceRoot: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", sourceRoot.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func minimalZIP(
        path: String,
        flags: UInt16 = 0,
        compressedBytes: Int = 1,
        uncompressedBytes: Int = 1
    ) -> Data {
        let name = Data(path.utf8)
        var local = Data()
        append(0x0403_4B50 as UInt32, to: &local)
        append(20 as UInt16, to: &local)
        append(flags, to: &local)
        append(0 as UInt16, to: &local)
        append(0 as UInt16, to: &local)
        append(0 as UInt16, to: &local)
        append(0 as UInt32, to: &local)
        append(UInt32(compressedBytes), to: &local)
        append(UInt32(uncompressedBytes), to: &local)
        append(UInt16(name.count), to: &local)
        append(0 as UInt16, to: &local)
        local.append(name)
        local.append(Data(repeating: 0x61, count: compressedBytes))

        var central = Data()
        append(0x0201_4B50 as UInt32, to: &central)
        append(0x0314 as UInt16, to: &central)
        append(20 as UInt16, to: &central)
        append(flags, to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt32, to: &central)
        append(UInt32(compressedBytes), to: &central)
        append(UInt32(uncompressedBytes), to: &central)
        append(UInt16(name.count), to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt16, to: &central)
        append(0 as UInt16, to: &central)
        append(UInt32(0o100600) << 16, to: &central)
        append(0 as UInt32, to: &central)
        central.append(name)

        var result = local
        let centralOffset = result.count
        result.append(central)
        append(0x0605_4B50 as UInt32, to: &result)
        append(0 as UInt16, to: &result)
        append(0 as UInt16, to: &result)
        append(1 as UInt16, to: &result)
        append(1 as UInt16, to: &result)
        append(UInt32(central.count), to: &result)
        append(UInt32(centralOffset), to: &result)
        append(0 as UInt16, to: &result)
        return result
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func toolInvocation(
        runID: RunID,
        projectID: ProjectID,
        toolName: String = "fs_read",
        result: String,
        createdAt: String = "2027-01-15T08:00:00Z"
    ) -> ToolInvocationRecord {
        ToolInvocationRecord(
            invocationID: UUID(),
            turnID: UUID(),
            runID: runID,
            sessionID: "fixture-session",
            projectID: projectID,
            projectGeneration: .initial,
            providerCallID: UUID().uuidString.lowercased(),
            toolName: toolName,
            replayClass: .readOnly,
            idempotencyKey: nil,
            argumentsSHA256: String(repeating: "a", count: 64),
            reconciliationDescriptor: nil,
            state: .completed,
            resultSHA256: JSONSupport.sha256Hex(result),
            resultSummary: result,
            lastErrorCode: nil,
            lastErrorSummary: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func shellResult(command: String, ok: Bool) throws -> String {
        let object: [String: Any] = [
            "is_error": !ok,
            "ok": ok,
            "payload": [
                "command": command,
                "cwd": "/tmp/fixture",
                "exit_code": ok ? 0 : 1,
                "ok": ok,
                "timed_out": false,
            ],
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func completionPlan(
        projectID: ProjectID,
        digest: String,
        kinds: [CompletionObligationKind]
    ) throws -> AutomaticCompletionPlan {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-completion-evidence-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("// swift-tools-version: 6.2\n".utf8).write(
            to: root.appendingPathComponent("Package.swift"),
            options: .atomic
        )
        let readOnly = kinds.contains(.readOnlyReportDelivered)
        let plan = try AutomaticCompletionPlanResolver.resolve(.init(
            projectID: projectID,
            projectGeneration: .initial,
            projectRoot: root,
            instructionArtifactSHA256: [digest],
            instructionText: readOnly
                ? "Audit the project and deliver a read-only report."
                : "Repair the Swift defect and run the affected tests.",
            documentCount: 1,
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
        ))
        XCTAssertEqual(Set(plan.obligations.map(\.kind)), Set(kinds))
        return plan
    }

    private func completionRun(
        runID: RunID,
        projectID: ProjectID,
        digest: String,
        plan: AutomaticCompletionPlan
    ) -> AutonomousRunRecord {
        AutonomousRunRecord(
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
                allowedTools: ["fs_read", "shell_exec"],
                completionGates: [ProjectInstructionQueueStore.builtInCompletionGate],
                completionPlan: plan,
                work: AutonomousRunWork(metadata: [
                    "source_snapshot_sha256": digest,
                    "completion_plan_id": plan.planID.uuidString.lowercased(),
                    "completion_plan_revision": String(plan.revision),
                ])
            ),
            completionRequestJSON: "{}",
            lastErrorCode: nil,
            lastErrorSummary: nil,
            retryAt: nil,
            continuationPending: false,
            revision: 8,
            createdAt: "2027-01-15T08:00:00Z",
            updatedAt: "2027-01-15T08:00:03Z"
        )
    }
}

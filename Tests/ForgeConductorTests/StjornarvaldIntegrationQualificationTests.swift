import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldIntegrationQualificationTests: XCTestCase {
    func testDeclaredRoleMetadataPreservesLegacyWireAndRejectsMalformedAdmission() async throws {
        let legacy = Data(#"{"shippingRuntimePaths":["Resources/renamed.js"],"targetMembershipComplete":true}"#.utf8)
        let decoder = JSONDecoder()
        let evidence = try decoder.decode(NativeTargetObservationEvidence.self, from: legacy)
        XCTAssertNil(evidence.declaredPathRoles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [String: Any])
        XCTAssertEqual(Set(legacyObject.keys), ["shippingRuntimePaths", "targetMembershipComplete"])
        let typed = NativeTargetObservationEvidence(shippingRuntimePaths: ["Resources/renamed.js"],
            targetMembershipComplete: true, declaredPathRoles: ["Resources/renamed.js": [.resource]])
        XCTAssertEqual(try decoder.decode(NativeTargetObservationEvidence.self, from: encoder.encode(typed)), typed)
        for malformed in [
            #"{"shippingRuntimePaths":["Resources/renamed.js"],"targetMembershipComplete":true,"declaredPathRoles":{"Resources/renamed.js":["browser_safe"]}}"#,
            #"{"shippingRuntimePaths":["Resources/renamed.js"],"targetMembershipComplete":true,"declaredPathRoles":{"Resources/renamed.js":"resource"}}"#,
        ] {
            XCTAssertThrowsError(try decoder.decode(NativeTargetObservationEvidence.self, from: Data(malformed.utf8)))
        }
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let repository = try StjornarvaldObservationRepository(databaseURL: fixture.root.appendingPathComponent("roles.sqlite3"))
        let invalid: [[String: [NativeTargetDeclaredRole]]] = [
            ["Resources/omitted.js": [.resource]], ["Resources/renamed.js": []],
            ["Resources/renamed.js": [.resource, .resource]],
        ]
        for roles in invalid {
            let native = NativeTargetObservationEvidence(shippingRuntimePaths: ["Resources/renamed.js"],
                targetMembershipComplete: true, declaredPathRoles: roles)
            XCTAssertFalse(NativeTargetDeclaredRole.valid(roles, paths: native.shippingRuntimePaths))
            let observation = DevelopmentObservation(idempotencyKey: UUID().uuidString,
                kind: .projectConfigurationObserved, subjectIdentity: "bounded-role-admission",
                summary: "Invalid role metadata", payloadSHA256: String(repeating: "a", count: 64),
                details: DevelopmentObservationDetails(nativeTarget: native))
            XCTAssertThrowsError(try repository.submit(observation))
            let findings = try await RavenNativeStackObservationDetector().evaluate(
                observation: observation, rules: RavenForgeDevelopmentPolicyAdapter().rules())
            XCTAssertEqual(findings.first?.disposition, .violation)
            XCTAssertFalse(findings.first?.candidate.assumptions.isEmpty ?? true)
        }
        XCTAssertTrue(try repository.pending(after: 0).isEmpty)
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first { $0.id.rawValue == "RFD-NATIVE-001" })
        let cannotClear = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
            subjectIdentity: "bounded-role-admission", shippingRuntimePaths: [], evidenceReferences: [],
            targetMembershipComplete: true, declaredPathRoles: ["Resources/omitted.js": [.resource]]),
            rule: rule, priorViolationOpen: true)
        XCTAssertEqual(cannotClear.state, .ambiguous)
        XCTAssertTrue(cannotClear.summary.contains("malformed"))
        // Unknown self-declared browser flags do not acquire a recognized graph role.
        let forgedBrowser = try decoder.decode(NativeTargetObservationEvidence.self, from: Data(
            #"{"shippingRuntimePaths":["Resources/renamed.js"],"targetMembershipComplete":true,"browserSafe":true}"#.utf8))
        let legacyPositive = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
            subjectIdentity: "unattested-browser-claim", shippingRuntimePaths: forgedBrowser.shippingRuntimePaths,
            evidenceReferences: [], targetMembershipComplete: true), rule: rule)
        XCTAssertEqual(legacyPositive.state, .violation)
        XCTAssertEqual(legacyPositive.confidence, 0.99)
    }

    func testDeclaredPhaseRolesUnionAliasesAndKeepSourceCopyPythonAndLegacyPositive() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let path = "Resources/renamed-diagnostic.js"
        try configureDeclaredScriptResource(fixture, path: path)
        let resource = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(resource.limitations, [])
        XCTAssertEqual(resource.declaredPathRoles[path], [.resource])
        try fixture.mutateGraph {
            var children = $0["GROUP"]?["children"] as? [String] ?? []
            children.append(contentsOf: ["SCRIPT_SOURCE_ALIAS", "SCRIPT_COPY_ALIAS"])
            $0["GROUP"]?["children"] = children
            for (reference, build) in [("SCRIPT_SOURCE_ALIAS", "BUILD_SCRIPT_SOURCE"), ("SCRIPT_COPY_ALIAS", "BUILD_SCRIPT_COPY")] {
                $0[reference] = ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": path]
                $0[build] = ["isa": "PBXBuildFile", "fileRef": reference]
            }
            $0["SOURCES"]?["files"] = ["BUILD_SWIFT", "BUILD_SCRIPT_SOURCE"]
            $0["COPY"] = ["isa": "PBXCopyFilesBuildPhase", "files": ["BUILD_SCRIPT_COPY"]]
            $0["APP"]?["buildPhases"] = ["SOURCES", "RESOURCES", "COPY", "AUTOMATION"]
        }
        let aliased = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(aliased.limitations, [])
        XCTAssertEqual(aliased.paths.filter { $0 == path }.count, 1)
        XCTAssertEqual(Set(aliased.declaredPathRoles[path] ?? []), [.source, .resource, .copy])
        XCTAssertNotEqual(aliased.digest, resource.digest)
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first { $0.id.rawValue == "RFD-NATIVE-001" })
        let multiRole = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
            subjectIdentity: "phase-aliases", shippingRuntimePaths: aliased.paths, evidenceReferences: [],
            targetMembershipComplete: true, declaredPathRoles: aliased.declaredPathRoles), rule: rule)
        XCTAssertEqual(multiRole.state, .violation)
        XCTAssertEqual(multiRole.confidence, 0.99)
        let positives: [(String, [NativeTargetDeclaredRole]?)] = [
            ("Resources/worker.py", [.resource]), (path, [.source]), (path, [.copy]),
            (path, [.synchronized]), (path, nil), ("ForeignFrontend/app.js", nil),
        ]
        for (file, roles) in positives {
            let assessment = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
                subjectIdentity: "positive-controls", shippingRuntimePaths: [file], evidenceReferences: [],
                targetMembershipComplete: true, declaredPathRoles: roles.map { [file: $0] }), rule: rule)
            XCTAssertEqual(assessment.state, .violation, file)
            XCTAssertEqual(assessment.confidence, 0.99, file)
        }
        let mixed = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
            subjectIdentity: "mixed-resource-controls", shippingRuntimePaths: [path, "Resources/worker.py"],
            evidenceReferences: [], targetMembershipComplete: true,
            declaredPathRoles: [path: [.resource], "Resources/worker.py": [.resource]]), rule: rule)
        XCTAssertEqual(mixed.state, .violation)
        XCTAssertEqual(mixed.confidence, 0.99)
        let selfDeclaredResource = RavenNativeStackDetector().evaluate(RavenNativeStackEvidence(
            subjectIdentity: "unattested-resource-role", shippingRuntimePaths: [path], evidenceReferences: [],
            targetMembershipComplete: true, declaredPathRoles: [path: [.resource]]), rule: rule, priorViolationOpen: true)
        XCTAssertEqual(selfDeclaredResource.state, .ambiguous)
        XCTAssertTrue(selfDeclaredResource.assumptions.contains { $0.contains("not runtime-use or producer-authenticity proof") })
    }

    func testDeclaredRoleTransportOverflowEmitsIncompleteActivityRatherThanCorrection() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeGraph(synchronized: true)
        let small = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(small.limitations, [])
        XCTAssertEqual(small.declaredPathRoles["Production/App.swift"], [.synchronized])
        for index in 0..<500 {
            let name = "\(index)-" + String(repeating: "r", count: 210) + ".js"
            try Data("fixture".utf8).write(to: fixture.project.appendingPathComponent("Production/\(name)"))
        }
        let capture = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(capture.limitations.contains("membership path/role payload exceeded its transport budget"))
        let native = NativeTargetObservationEvidence(shippingRuntimePaths: capture.paths,
            targetMembershipComplete: false, declaredPathRoles: capture.declaredPathRoles)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(native).count,
            StjornarvaldNativeTargetMembership.maximumMembershipPayloadBytes + 256)
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:bounded-role-activity")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let tool = StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
            result: .success(["jobs": []]), context: context, clientID: client)
        let produced = await producer.observation(after: tool)
        let observation = try XCTUnwrap(produced)
        XCTAssertNil(observation.details?.nativeTarget)
        XCTAssertTrue(observation.summary.contains("incomplete"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertLessThanOrEqual(try encoder.encode(observation).count,
            StjornarvaldObservationRepository.maximumObservationBytes)
        let repository = try StjornarvaldObservationRepository(databaseURL: fixture.root.appendingPathComponent("bounded.sqlite3"))
        XCTAssertNoThrow(try repository.submit(observation))
        let findings = try await RavenNativeStackObservationDetector().evaluate(
            observation: observation, rules: RavenForgeDevelopmentPolicyAdapter().rules())
        XCTAssertTrue(findings.isEmpty)
    }

    func testResourceReviewRetainsPriorViolationHistoricalEventBytesAndModelNotice() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:resource-review-history")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let detector = RavenNativeStackObservationDetector()
        let rules = RavenForgeDevelopmentPolicyAdapter().rules()
        let database = fixture.root.appendingPathComponent("history-role.sqlite3")
        let log = try StjornarvaldPolicyLogStore(databaseURL: database,
            jsonlURL: fixture.root.appendingPathComponent("history-role.jsonl"))
        let notices = try StjornarvaldPolicyNoticeRepository(databaseURL: database)
        let lifecycle = StjornarvaldViolationLifecycleService(store: log)
        func tool() -> DevelopmentObservation {
            StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
                result: .success(["jobs": []]), context: context, clientID: client)
        }
        let produced = await producer.observation(after: tool())
        let original = try XCTUnwrap(produced)
        let originalFindings = try await detector.evaluate(observation: original, rules: rules)
        let originalFinding = try XCTUnwrap(originalFindings.first)
        XCTAssertEqual(originalFinding.candidate.confidence, 0.99)
        let start = Date()
        guard case .recorded(let firstViolation, let firstEvent) = try lifecycle.apply(originalFinding, occurredAt: start) else {
            return XCTFail("Python production resource must open a retained violation")
        }
        XCTAssertNotNil(try notices.queue(firstEvent, now: start))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let historicalBytes = try encoder.encode(firstEvent)
        await producer.confirmRetention(of: original)
        try configureDeclaredScriptResource(fixture, path: "Resources/renamed-diagnostic.mjs")
        let reviewed = await producer.observation(after: tool())
        let review = try XCTUnwrap(reviewed)
        let reviewFindings = try await detector.evaluate(observation: review, rules: rules)
        let finding = try XCTUnwrap(reviewFindings.first)
        XCTAssertEqual(finding.disposition, .violation)
        XCTAssertEqual(finding.candidate.confidence, 0.45)
        let afterQuietInterval = start.addingTimeInterval(StjornarvaldPolicyNoticeRepository.repeatQuietInterval + 1)
        guard case .recorded(let currentViolation, let event) = try lifecycle.apply(finding, occurredAt: afterQuietInterval) else {
            return XCTFail("Ambiguity must retain the advisory violation")
        }
        XCTAssertEqual(currentViolation.id, firstViolation.id)
        XCTAssertEqual(currentViolation.state, .repeated)
        XCTAssertEqual(event.type, .repeated)
        XCTAssertEqual(try log.events().map(\.type), [.opened, .repeated])
        let historical = try XCTUnwrap(try log.event(id: firstEvent.id))
        XCTAssertEqual(try encoder.encode(historical), historicalBytes)
        let notice = try XCTUnwrap(try notices.queue(event, now: afterQuietInterval))
        XCTAssertEqual(notice.confidence, 0.45)
        XCTAssertTrue(notice.summary.contains("review"))
        let target = StjornarvaldPolicyNoticeRepository.mcpTargetIdentity(
            projectID: context.projectID.description, generation: Int(context.projectGeneration.rawValue),
            clientID: client.rawValue)
        let pending = try notices.pending(targetKind: .mcpClient, targetIdentity: target,
            maximumCount: 8, maximumBytes: 16 * 1_024)
        XCTAssertTrue(pending.contains { $0.id == notice.id })
        let presentation = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(notices: [notice]))
        XCTAssertTrue(presentation.contains("STJORNARVALD POLICY NOTICE"))
        XCTAssertTrue(presentation.contains("review"))
        XCTAssertTrue(presentation.contains("Confidence: 0.45"))
        XCTAssertFalse(finding.controlsExecution)
    }

    private func configureDeclaredScriptResource(_ fixture: NativeMembershipFixture, path: String) throws {
        try fixture.writeGraph(includeWorker: false)
        let asset = fixture.project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("globalThis.fixture = true;\n".utf8).write(to: asset)
        try fixture.mutateGraph {
            var children = $0["GROUP"]?["children"] as? [String] ?? []
            children.append("SCRIPT_RESOURCE")
            $0["GROUP"]?["children"] = children
            $0["SCRIPT_RESOURCE"] = ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": path]
            $0["BUILD_SCRIPT_RESOURCE"] = ["isa": "PBXBuildFile", "fileRef": "SCRIPT_RESOURCE"]
            $0["RESOURCES"]?["files"] = ["BUILD_SCRIPT_RESOURCE"]
        }
    }
    func testNativeResourceOnlyJavaScriptRetainsAdvisoryFindingWithoutRuntimeCertainty() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeGraph(includeWorker: false)
        let relative = "Resources/renamed-diagnostic.mjs"
        let asset = fixture.project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("globalThis.fixture = true;\n".utf8).write(to: asset)
        try fixture.mutateGraph {
            var children = $0["GROUP"]?["children"] as? [String] ?? []
            children.append("SCRIPT_RESOURCE")
            $0["GROUP"]?["children"] = children
            $0["SCRIPT_RESOURCE"] = ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": relative]
            $0["BUILD_SCRIPT_RESOURCE"] = ["isa": "PBXBuildFile", "fileRef": "SCRIPT_RESOURCE"]
            $0["RESOURCES"]?["files"] = ["BUILD_SCRIPT_RESOURCE"]
        }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:resource-review-baseline")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let tool = StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
            result: .success(["jobs": []]), context: context, clientID: client)
        let produced = await producer.observation(after: tool)
        let observation = try XCTUnwrap(produced)
        XCTAssertEqual(observation.details?.nativeTarget?.targetMembershipComplete, true)
        XCTAssertTrue(observation.details?.nativeTarget?.shippingRuntimePaths.contains(relative) == true)
        let findings = try await RavenNativeStackObservationDetector().evaluate(
            observation: observation, rules: RavenForgeDevelopmentPolicyAdapter().rules())
        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.disposition, .violation)
        XCTAssertEqual(finding.candidate.conditionIdentity, "interpreted_shipping_runtime")
        XCTAssertTrue(finding.candidate.evidenceReferences.contains(relative))
        XCTAssertLessThanOrEqual(finding.candidate.confidence, 0.5,
            "Resource declaration alone does not establish application runtime use.")
        XCTAssertTrue(finding.candidate.summary.contains("review"))
        XCTAssertFalse(finding.candidate.assumptions.isEmpty)
        XCTAssertFalse(finding.candidate.alternatives.isEmpty)
    }

    func testNativeMembershipUsesProductionTargetsAndSynchronizedExceptions() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let conventional = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(conventional.limitations, [])
        XCTAssertEqual(conventional.paths, ["Production/App.swift", "Production/worker.py"])
        XCTAssertFalse(conventional.paths.contains("Tests/test-worker.py"))
        XCTAssertFalse(conventional.paths.contains("Build/build-helper.sh"))

        try fixture.writeGraph(synchronized: true)
        let synchronized = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(synchronized.limitations, [])
        XCTAssertEqual(synchronized.paths, conventional.paths)
        XCTAssertFalse(synchronized.paths.contains("Production/Support/analysis.py"))
        XCTAssertNotEqual(synchronized.digest, conventional.digest)

        try fixture.writeGraph(synchronized: true, unsupportedException: true)
        let unsupported = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertFalse(unsupported.limitations.isEmpty)
        XCTAssertTrue(unsupported.limitations.contains(
            "synchronized-group exception semantics are unsupported"))
    }

    func testNativeMembershipReadsCanonicalWorkspaceAndOptionalHostSynchronizedProject() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let canonical = StjornarvaldNativeTargetMembership.capture(root: repository)
        XCTAssertEqual(canonical.limitations, [])
        XCTAssertTrue(canonical.paths.contains(
            "Sources/ForgeConductorCore/Application/StjornarvaldNativeTargetObservationProducer.swift"))
        XCTAssertFalse(canonical.paths.contains(where: { $0.hasPrefix("Tests/") || $0.hasPrefix("script/") }))
        if let path = ProcessInfo.processInfo.environment["FORGE_STJ_NATIVE_PROJECT_PATH"] {
            let current = StjornarvaldNativeTargetMembership.capture(root: URL(fileURLWithPath: path))
            XCTAssertEqual(current.limitations, [])
            XCTAssertGreaterThan(current.paths.count, 0)
            XCTAssertTrue(current.paths.contains(where: { $0.hasPrefix("JamfTechnicianApp/") }))
            XCTAssertFalse(current.paths.contains(where: {
                $0.hasPrefix("JamfTechnicianTests/") || $0.hasPrefix("JamfTechnicianUITests/")
                    || $0 == "JamfTechnicianApp/Supporting Files/Info.plist"
            }))
        }
    }

    func testCanonicalBrowserAssetsRemainDeclaredSourceFindingsAndNativeHTTPResources() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let capture = StjornarvaldNativeTargetMembership.capture(root: repository)
        XCTAssertEqual(capture.limitations, [])
        let browserAssets: Set<String> = [
            "Sources/ForgeConductorCore/Resources/TelemetryStatic/app.js",
            "Sources/ForgeConductorCore/Resources/TelemetryStatic/tools-catalog.js",
        ]
        XCTAssertTrue(browserAssets.isSubset(of: Set(capture.paths)))
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first {
            $0.id.rawValue == "RFD-NATIVE-001"
        })
        let detector = RavenNativeStackDetector()
        let assessment = detector.evaluate(RavenNativeStackEvidence(subjectIdentity: "canonical-native-targets",
            shippingRuntimePaths: capture.paths, evidenceReferences: ["declared-source-resource-copy"],
            targetMembershipComplete: true), rule: rule)
        XCTAssertEqual(assessment.state, .violation)
        XCTAssertEqual(Set(assessment.evidenceReferences.filter { $0.hasSuffix(".js") }), browserAssets)
        XCTAssertTrue(assessment.summary.contains("declared production source/resource/copy membership"))
        let declaredAssessment = detector.evaluate(RavenNativeStackEvidence(
            subjectIdentity: "canonical-native-targets", shippingRuntimePaths: capture.paths,
            evidenceReferences: ["declared-source-resource-copy"], targetMembershipComplete: true,
            declaredPathRoles: capture.declaredPathRoles), rule: rule)
        XCTAssertEqual(declaredAssessment.state, .ambiguous)
        XCTAssertEqual(declaredAssessment.confidence, 0.45)
        XCTAssertEqual(Set(declaredAssessment.evidenceReferences.filter { $0.hasSuffix(".js") }), browserAssets)
        XCTAssertTrue(declaredAssessment.summary.contains("review"))
        // This preserves the declared-source heuristic. It proves neither an
        // interpreter inside the binary nor the policy applicability of browser diagnostics.
        for path in ["Production/worker.py", "ForeignFrontend/app.js"] {
            let control = detector.evaluate(RavenNativeStackEvidence(subjectIdentity: "unclassified-runtime",
                shippingRuntimePaths: [path], evidenceReferences: [], targetMembershipComplete: true), rule: rule)
            XCTAssertEqual(control.state, .violation)
            XCTAssertTrue(control.evidenceReferences.contains(path))
        }

        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        let server = DashboardServer(app: app, host: "127.0.0.1", port: UInt16.random(in: 30_000...39_000))
        try server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for asset in browserAssets.sorted() {
            let name = URL(fileURLWithPath: asset).lastPathComponent
            let (data, response) = try await session.data(from: server.baseURL.appendingPathComponent("static").appendingPathComponent(name))
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/javascript") == true)
            XCTAssertEqual(data, try Data(contentsOf: repository.appendingPathComponent(asset)))
        }
        let (index, response) = try await session.data(from: server.baseURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: index, encoding: .utf8)?.contains("<script src=\"/static/app.js\"></script>") == true)
        XCTAssertFalse(app.telemetry.realtimeEngine.isRunning)
    }

    func testNativeMembershipUsesDeclaredTargetsAndRejectsExcludedProductEmbedding() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeGraph(includeWorker: false)
        try fixture.mutateGraph { objects in
            objects["ORPHAN"] = ["isa": "PBXNativeTarget",
                "productType": "com.apple.product-type.application", "buildPhases": ["ORPHAN_RESOURCES"]]
            objects["ORPHAN_RESOURCES"] = ["isa": "PBXResourcesBuildPhase", "files": ["BUILD_PYTHON"]]
        }
        let declared = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(declared.limitations, [])
        XCTAssertEqual(declared.paths, ["Production/App.swift"])
        try fixture.mutateGraph { objects in
            objects["TEST_PRODUCT"] = ["isa": "PBXFileReference", "sourceTree": "BUILT_PRODUCTS_DIR",
                                        "path": "FixtureTests.xctest"]
            objects["TEST"]?["productReference"] = "TEST_PRODUCT"
            objects["EMBED_TEST"] = ["isa": "PBXBuildFile", "fileRef": "TEST_PRODUCT"]
            objects["COPY"] = ["isa": "PBXCopyFilesBuildPhase", "files": ["EMBED_TEST"]]
            objects["APP"]?["buildPhases"] = ["SOURCES", "RESOURCES", "COPY"]
        }
        let embedded = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(embedded.limitations.contains("production file reference is unresolved"))
    }

    func testNativeMembershipIncludesHiddenCopiedResourcesAndMarksSynchronizedHiddenEntriesIncomplete() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let resource = fixture.project.appendingPathComponent("Resources/.worker.py")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: resource)
        try fixture.mutateGraph { objects in
            var children = objects["GROUP"]?["children"] as? [String] ?? []
            children.append("COPIED_DIRECTORY")
            objects["GROUP"]?["children"] = children
            objects["COPIED_DIRECTORY"] = ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT",
                                             "path": "Resources", "lastKnownFileType": "folder"]
            objects["BUILD_DIRECTORY"] = ["isa": "PBXBuildFile", "fileRef": "COPIED_DIRECTORY"]
            objects["RESOURCES"]?["files"] = ["BUILD_DIRECTORY"]
        }
        let conventional = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(conventional.limitations, [])
        XCTAssertTrue(conventional.paths.contains("Resources/.worker.py"))

        let synchronizedHidden = fixture.project.appendingPathComponent("Production/.worker.py")
        try Data("fixture".utf8).write(to: synchronizedHidden)
        try fixture.writeGraph(synchronized: true)
        let synchronized = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(synchronized.limitations.contains("synchronized hidden-entry membership semantics are unsupported"))
        try fixture.mutateGraph { objects in
            objects["EXCEPTION"]?["membershipExceptions"] = ["Support/analysis.py", ".worker.py"]
        }
        let excluded = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertEqual(excluded.limitations, [])
        XCTAssertFalse(excluded.paths.contains("Production/.worker.py"))
    }

    func testNativeMembershipBoundsProjectBytesDepthAndTransportPayload() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let projectFile = fixture.project.appendingPathComponent("Fixture.xcodeproj/project.pbxproj")
        try Data(repeating: 0x20, count: StjornarvaldNativeTargetMembership.maximumProjectBytes + 1)
            .write(to: projectFile)
        XCTAssertFalse(StjornarvaldNativeTargetMembership.capture(root: fixture.project).limitations.isEmpty)
        try fixture.writeGraph(synchronized: true)
        for index in 0..<800 {
            let name = "\(index)-" + String(repeating: "x", count: 180) + ".swift"
            try Data().write(to: fixture.project.appendingPathComponent("Production/\(name)"))
        }
        let bounded = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(bounded.limitations.contains("membership path payload exceeded its transport budget"))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(bounded.paths).count,
                                StjornarvaldNativeTargetMembership.maximumPathPayloadBytes + 1)
        var graph = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: projectFile), format: nil) as? [String: Any])
        var objects = try XCTUnwrap(graph["objects"] as? [String: [String: Any]])
        for index in 0..<70 {
            objects["DEEP\(index)"] = ["isa": "PBXGroup", "sourceTree": "<group>",
                                      "children": index == 69 ? [] : ["DEEP\(index + 1)"]]
        }
        objects["GROUP"]?["children"] = ["DEEP0"]
        graph["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: graph, format: .xml, options: 0).write(to: projectFile)
        XCTAssertTrue(StjornarvaldNativeTargetMembership.capture(root: fixture.project).limitations.contains(
            "group traversal exceeded its depth or deadline"))
    }

    func testNativeMembershipRejectsMalformedMandatoryAndPresentOptionalArraysButRetainsValidEmptyArrays() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let mutations: [(String, (inout [String: [String: Any]]) -> Void)] = [
            ("missing target phases", { _ = $0["APP"]?.removeValue(forKey: "buildPhases") }),
            ("wrong target phases", { $0["APP"]?["buildPhases"] = "SOURCES" }),
            ("missing source files", { _ = $0["SOURCES"]?.removeValue(forKey: "files") }),
            ("wrong source files", { $0["SOURCES"]?["files"] = "BUILD_SWIFT" }),
            ("missing resource files", { _ = $0["RESOURCES"]?.removeValue(forKey: "files") }),
            ("wrong resource files", { $0["RESOURCES"]?["files"] = "BUILD_PYTHON" }),
            ("missing copy files", {
                $0["COPY"] = ["isa": "PBXCopyFilesBuildPhase"]
                $0["APP"]?["buildPhases"] = ["SOURCES", "COPY"]
            }),
            ("wrong copy files", {
                $0["COPY"] = ["isa": "PBXCopyFilesBuildPhase", "files": "BUILD_PYTHON"]
                $0["APP"]?["buildPhases"] = ["SOURCES", "COPY"]
            }),
            ("wrong optional synchronized groups", { $0["APP"]?["fileSystemSynchronizedGroups"] = "PRODUCTION" }),
        ]
        for (name, mutation) in mutations {
            try fixture.writeGraph()
            try fixture.mutateGraph(mutation)
            XCTAssertFalse(StjornarvaldNativeTargetMembership.capture(root: fixture.project).limitations.isEmpty, name)
        }
        try fixture.writeGraph(synchronized: true)
        try fixture.mutateGraph { $0["PRODUCTION"]?["exceptions"] = "EXCEPTION" }
        XCTAssertFalse(StjornarvaldNativeTargetMembership.capture(root: fixture.project).limitations.isEmpty)

        try fixture.writeGraph()
        try fixture.mutateGraph {
            $0["APP"]?["buildPhases"] = [String]()
            _ = $0["APP"]?.removeValue(forKey: "fileSystemSynchronizedGroups")
        }
        let emptyTarget = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(emptyTarget.limitations.isEmpty)
        XCTAssertTrue(emptyTarget.paths.isEmpty)
        try fixture.writeGraph()
        try fixture.mutateGraph {
            $0["SOURCES"]?["files"] = [String]()
            $0["RESOURCES"]?["files"] = [String]()
        }
        let emptyPhases = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(emptyPhases.limitations.isEmpty)
        XCTAssertTrue(emptyPhases.paths.isEmpty)
    }

    func testNativeMembershipRejectsMalformedRootAndGroupReferences() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let mutations: [(String, (inout [String: [String: Any]]) -> Void)] = [
            ("missing main group", { _ = $0.removeValue(forKey: "GROUP") }),
            ("wrong main group kind", { $0["GROUP"]?["isa"] = "PBXFileReference" }),
            ("missing group children", { _ = $0["GROUP"]?.removeValue(forKey: "children") }),
            ("wrong group children", { $0["GROUP"]?["children"] = "SWIFT" }),
            ("missing root targets", { _ = $0["ROOT"]?.removeValue(forKey: "targets") }),
            ("wrong root targets", { $0["ROOT"]?["targets"] = "APP" }),
            ("wrong reference path", { $0["SWIFT"]?["path"] = 7 }),
            ("wrong reference source tree", { $0["SWIFT"]?["sourceTree"] = 7 }),
        ]
        for (name, mutation) in mutations {
            try fixture.writeGraph()
            try fixture.mutateGraph { objects in
                objects["APP"]?["buildPhases"] = [String]()
                mutation(&objects)
            }
            XCTAssertFalse(StjornarvaldNativeTargetMembership.capture(root: fixture.project).limitations.isEmpty, name)
        }
        try fixture.writeGraph()
        try fixture.mutateGraph {
            $0["APP"]?["buildPhases"] = [String]()
            $0["GROUP"]?["children"] = [String]()
        }
        let emptyGroup = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertTrue(emptyGroup.limitations.isEmpty)
        XCTAssertTrue(emptyGroup.paths.isEmpty)
    }

    func testMalformedNativeCaptureCannotCorrectRecordedViolationUntilValidGraphRepair() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:malformed-membership-history")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let detector = RavenNativeStackObservationDetector()
        let rules = RavenForgeDevelopmentPolicyAdapter().rules()
        let log = try StjornarvaldPolicyLogStore(databaseURL: fixture.root.appendingPathComponent("history.sqlite3"),
            jsonlURL: fixture.root.appendingPathComponent("history.jsonl"))
        let lifecycle = StjornarvaldViolationLifecycleService(store: log)
        func tool() -> DevelopmentObservation {
            StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
                result: .success(["jobs": []]), context: context, clientID: client)
        }
        let openedOptional = await producer.observation(after: tool())
        let opened = try XCTUnwrap(openedOptional)
        let violations = try await detector.evaluate(observation: opened, rules: rules)
        XCTAssertEqual(violations.count, 1)
        _ = try lifecycle.apply(try XCTUnwrap(violations.first), occurredAt: opened.observedAt)
        await producer.confirmRetention(of: opened)
        XCTAssertEqual(try log.events().map(\.type), [.opened])

        for wrongType in [false, true] {
            try fixture.writeGraph()
            try fixture.mutateGraph {
                if wrongType { $0["RESOURCES"]?["files"] = "BUILD_PYTHON" }
                else { _ = $0["RESOURCES"]?.removeValue(forKey: "files") }
            }
            let malformedOptional = await producer.observation(after: tool())
            let malformed = try XCTUnwrap(malformedOptional)
            XCTAssertNil(malformed.details?.nativeTarget)
            XCTAssertTrue(malformed.summary.contains("incomplete"))
            let findings = try await detector.evaluate(observation: malformed, rules: rules)
            XCTAssertTrue(findings.isEmpty)
            for finding in findings { _ = try lifecycle.apply(finding, occurredAt: malformed.observedAt) }
            XCTAssertEqual(try log.events().map(\.type), [.opened])
        }
        try fixture.writeGraph(includeWorker: false)
        let repairedOptional = await producer.observation(after: tool())
        let repaired = try XCTUnwrap(repairedOptional)
        XCTAssertEqual(repaired.details?.nativeTarget?.targetMembershipComplete, true)
        let corrections = try await detector.evaluate(observation: repaired, rules: rules)
        XCTAssertEqual(corrections.count, 1)
        _ = try lifecycle.apply(try XCTUnwrap(corrections.first), occurredAt: repaired.observedAt)
        XCTAssertEqual(try log.events().map(\.type), [.opened, .corrected])
        XCTAssertEqual(try log.violations().first?.violation.state, .corrected)
    }

    func testNativeMembershipVisitBudgetStopsRepeatedSharedPhaseWorkBeforeDeduplication() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeSharedPhaseGraph()
        let clock = NativeMembershipCountingClock()
        let capture = StjornarvaldNativeTargetMembership.capture(root: fixture.project, clock: clock)
        XCTAssertEqual(capture.paths, ["Production/App.swift"])
        XCTAssertEqual(capture.limitations, ["membership traversal exceeded its bound"])
        XCTAssertLessThan(clock.readCount, 50_000,
            "A frozen clock must not let traversal continue through all 8 × 8192 repeated memberships after the visit budget expires")
        let repeated = StjornarvaldNativeTargetMembership.capture(root: fixture.project,
            clock: NativeMembershipCountingClock())
        XCTAssertEqual(repeated.digest, capture.digest)
        XCTAssertEqual(repeated.limitations, capture.limitations)
    }

    func testNativeMembershipDeadlineStopsRemainingSharedPhaseWorkWithStableIncompleteDigest() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeSharedPhaseGraph()
        let clock = NativeMembershipCountingClock(expiringAfterReads: 96)
        let capture = StjornarvaldNativeTargetMembership.capture(root: fixture.project, clock: clock)
        XCTAssertEqual(capture.paths, ["Production/App.swift"])
        XCTAssertEqual(capture.limitations, ["membership traversal exceeded its deadline"])
        XCTAssertLessThanOrEqual(clock.readCount, 110,
            "A fixed deadline must terminate all remaining target/phase loops rather than merely stop adding unique paths")
        let repeated = StjornarvaldNativeTargetMembership.capture(root: fixture.project,
            clock: NativeMembershipCountingClock(expiringAfterReads: 96))
        XCTAssertEqual(repeated.digest, capture.digest)
        XCTAssertEqual(repeated.paths, capture.paths)
        XCTAssertEqual(repeated.limitations, capture.limitations)
    }

    func testNativeMembershipRejectsFIFOWithoutWaitingForAWriter() throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let graph = fixture.project.appendingPathComponent("Fixture.xcodeproj/project.pbxproj")
        try FileManager.default.removeItem(at: graph)
        XCTAssertEqual(Darwin.mkfifo(graph.path, 0o600), 0)
        let clock = ContinuousClock()
        let started = clock.now
        let capture = StjornarvaldNativeTargetMembership.capture(root: fixture.project)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(capture.limitations, ["project file is not a regular file"])
        XCTAssertTrue(capture.paths.isEmpty)
    }

    /// Deterministic source parity only. No model, native build, or policy GUI is exercised.
    func testManagedNativeGraphCaptureUsesAcceptedSessionScopeAndSeparateRetentionIdentity() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:managed-native-policy-parity")
        let repository = app.projectContexts.repository
        let project = try await repository.registerProjectUnchecked(projectID: ProjectID(),
            displayName: "Managed native policy parity", canonicalRoot: fixture.project)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        _ = try await repository.bind(owner: owner, projectID: project.projectID,
            generation: project.generation,
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [project.canonicalRoot],
                allowedTools: ["fs_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
        let ordinaryContext = try await repository.invocationContext(for: owner, clientID: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let ordinaryTool = StjornarvaldProductObservationFactory.ordinaryTool(name: "fs_write",
            result: .success(["ok": true]), context: ordinaryContext, clientID: client)
        let ordinaryProduced = await producer.observation(after: ordinaryTool)
        let ordinary = try XCTUnwrap(ordinaryProduced)
        await producer.confirmRetention(of: ordinary)

        // The same project/generation/client graph must still reach the detector
        // from each accepted managed run, rather than sharing the ordinary cache key.
        let managedContext = try await nativeManagedContext(app: app, project: project, clientID: client)
        let managedTool = StjornarvaldProductObservationFactory.managedTool(
            call: BrokeredToolCall(providerCallID: "managed-write", toolName: "fs_write", arguments: [:]),
            result: .success(["ok": true]), context: managedContext)
        let managedProduced = await producer.observation(after: managedTool)
        let managed = try XCTUnwrap(managedProduced,
            "A current accepted managed tool must capture declared native membership")
        XCTAssertEqual(managed.scope, managedTool.scope)
        XCTAssertNotNil(managed.scope.runID)
        XCTAssertEqual(managed.scope.sessionID, managedContext.providerSessionID)
        XCTAssertEqual(managed.details?.nativeTarget?.shippingRuntimePaths,
                       ["Production/App.swift", "Production/worker.py"])
        XCTAssertEqual(managed.details?.nativeTarget?.targetMembershipComplete, true)
        let findings = try await RavenNativeStackObservationDetector().evaluate(
            observation: managed, rules: RavenForgeDevelopmentPolicyAdapter().rules())
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.candidate.rule.id.rawValue, "RFD-NATIVE-001")
        XCTAssertEqual(findings.first?.disposition, .violation)
        let unconfirmed = await producer.observation(after: managedTool)
        XCTAssertNotNil(unconfirmed, "Only durable acceptance may suppress the next capture")
        await producer.confirmRetention(of: managed)
        let duplicate = await producer.observation(after: managedTool)
        XCTAssertNil(duplicate)

        let secondContext = try await nativeManagedContext(app: app, project: project, clientID: client)
        XCTAssertNotEqual(secondContext.runID, managedContext.runID)
        XCTAssertNotEqual(secondContext.providerSessionID, managedContext.providerSessionID)
        let secondTool = StjornarvaldProductObservationFactory.managedTool(
            call: BrokeredToolCall(providerCallID: "managed-second-write", toolName: "fs_write", arguments: [:]),
            result: .success(["ok": true]), context: secondContext)
        let secondProduced = await producer.observation(after: secondTool)
        let second = try XCTUnwrap(secondProduced, "A separate run/session owns a separate graph cache identity")
        XCTAssertEqual(second.scope, secondTool.scope)
        XCTAssertEqual(second.details?.nativeTarget, managed.details?.nativeTarget)
        let ordinaryReplay = await producer.observation(after: ordinaryTool)
        XCTAssertNil(ordinaryReplay, "Managed capture preserves ordinary durable deduplication")
    }

    func testManagedNativeGraphCaptureRejectsUnknownMismatchedAndStaleOwnership() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let foreignFixture = try NativeMembershipFixture()
        defer { foreignFixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        let repository = app.projectContexts.repository
        let project = try await repository.registerProjectUnchecked(projectID: ProjectID(),
            displayName: "Managed native policy owner", canonicalRoot: fixture.project)
        let foreign = try await repository.registerProjectUnchecked(projectID: ProjectID(),
            displayName: "Managed native policy foreign owner", canonicalRoot: foreignFixture.project)
        let client = ClientID("lm-studio:managed-native-policy-ownership")
        let context = try await nativeManagedContext(app: app, project: project, clientID: client)
        let valid = StjornarvaldProductObservationFactory.managedTool(
            call: BrokeredToolCall(providerCallID: "managed-owner-write", toolName: "fs_write", arguments: [:]),
            result: .success(["ok": true]), context: context)
        let scopes = [
            DevelopmentObservationScope(projectID: context.projectID.description,
                projectGeneration: Int(context.projectGeneration.rawValue), runID: context.runID?.description,
                sessionID: nil, clientID: client.rawValue),
            DevelopmentObservationScope(projectID: context.projectID.description,
                projectGeneration: Int(context.projectGeneration.rawValue), runID: context.runID?.description,
                sessionID: "unknown-managed-session", clientID: client.rawValue),
            DevelopmentObservationScope(projectID: context.projectID.description,
                projectGeneration: Int(context.projectGeneration.rawValue), runID: RunID().description,
                sessionID: context.providerSessionID, clientID: client.rawValue),
            DevelopmentObservationScope(projectID: foreign.projectID.description,
                projectGeneration: Int(foreign.generation.rawValue), runID: context.runID?.description,
                sessionID: context.providerSessionID, clientID: client.rawValue),
            DevelopmentObservationScope(projectID: context.projectID.description,
                projectGeneration: Int(context.projectGeneration.rawValue) + 1, runID: context.runID?.description,
                sessionID: context.providerSessionID, clientID: client.rawValue),
        ]
        for scope in scopes {
            let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
            let invalid = DevelopmentObservation(idempotencyKey: UUID().uuidString,
                kind: valid.kind, observedAt: valid.observedAt, scope: scope,
                subjectIdentity: valid.subjectIdentity, summary: valid.summary,
                evidenceReferences: valid.evidenceReferences, payloadSHA256: valid.payloadSHA256)
            let observed = await producer.observation(after: invalid)
            XCTAssertNil(observed, "A managed native graph cannot borrow another run/session/project generation")
        }
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let observed = await producer.observation(after: valid)
        XCTAssertNotNil(observed, "Rejecting stale/foreign ownership must preserve the valid accepted owner")
    }

    private func nativeManagedContext(app: ForgeApp, project: ProjectControlRecord,
                                      clientID: ClientID) async throws -> ToolInvocationContext {
        let repository = app.projectContexts.repository
        let created = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: project.projectID, projectGeneration: project.generation,
            mission: "Verify managed native policy observation scope",
            providerID: "native-policy-fixture", adapterID: "native-policy-fixture-adapter",
            modelKey: "native-policy-fixture-model",
            specification: AutonomousRunSpecification(allowedTools: ["fs_write"], completionGates: ["tests"]),
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [project.canonicalRoot],
                allowedTools: ["fs_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536)))
        let lease = try await repository.acquireRunLease(runID: created.runID, ownerID: "native-policy-fixture")
        let sessionID = "native-policy-session-" + UUID().uuidString.lowercased()
        try await repository.reserveProviderSession(ProviderSessionIntent(sessionID: sessionID,
            runID: created.runID, projectID: project.projectID, projectGeneration: project.generation,
            providerID: "native-policy-fixture", adapterID: "native-policy-fixture-adapter",
            modelKey: "native-policy-fixture-model", providerResponseID: "native-policy-root-" + sessionID,
            idempotencyKey: sessionID, contextCapacity: 262_144), lease: lease)
        _ = try await repository.releaseRunLease(lease)
        return try await repository.invocationContext(for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
            clientID: clientID)
    }

    func testNativeProducerFencesGenerationAndDeduplicatesSourceEvidence() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let client = ClientID("lm-studio:native-membership-control")
        let initialized = try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client)
        XCTAssertTrue(initialized.ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let tool = StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
            result: .success(["jobs": []]), context: context, clientID: client)
        let produced = await producer.observation(after: tool)
        let first = try XCTUnwrap(produced)
        XCTAssertEqual(first.scope, tool.scope)
        XCTAssertNil(first.scope.runID)
        XCTAssertEqual(first.details?.nativeTarget?.shippingRuntimePaths,
                       ["Production/App.swift", "Production/worker.py"])
        XCTAssertEqual(first.details?.nativeTarget?.targetMembershipComplete, true)
        let unconfirmed = await producer.observation(after: tool)
        XCTAssertNotNil(unconfirmed)
        await producer.confirmRetention(of: first)
        let duplicate = await producer.observation(after: tool)
        XCTAssertNil(duplicate)

        let stale = DevelopmentObservation(idempotencyKey: "stale-generation", kind: tool.kind,
            scope: DevelopmentObservationScope(projectID: context.projectID.description,
                projectGeneration: Int(context.projectGeneration.rawValue) + 1,
                clientID: client.rawValue), subjectIdentity: tool.subjectIdentity,
            summary: tool.summary, payloadSHA256: tool.payloadSHA256)
        let rejected = await producer.observation(after: stale)
        XCTAssertNil(rejected)
        try fixture.writeGraph(synchronized: true, unsupportedException: true)
        let incomplete = await producer.observation(after: tool)
        let partial = try XCTUnwrap(incomplete)
        XCTAssertNil(partial.details?.nativeTarget)
        XCTAssertTrue(partial.summary.contains("incomplete"))
    }

    func testOrdinaryMCPNativeViolationIsRecordedPresentedAndCorrectedWithoutChangingJobResult() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        try fixture.writeGraph(includeWorker: false)
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        let port = Int.random(in: 40_000...49_000)
        _ = try app.config.update(["dashboard": ["port": port],
                                  "allowed_roots": [fixture.root.path]], save: true)
        let manager = ManagerNode(app: app)
        defer { _ = try? manager.stopService(); _ = app.shutdown() }
        _ = try manager.startService()
        let client = ClientID("lm-studio:ordinary-policy-control")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let cache = StjornarvaldInteractivePolicyNoticeCache(paths: app.paths,
            projectID: context.projectID.description,
            projectGeneration: Int(context.projectGeneration.rawValue), clientID: client.rawValue)
        let server = MCPServer(app: app, clientID: client, policyNoticeProvider: cache)
        let wire = PolicyNoticeWire(server: server)
        wire.start()
        defer { XCTAssertNil(wire.stop()) }
        let observations = try StjornarvaldObservationRepository(paths: app.paths)
        let notices = try StjornarvaldPolicyNoticeRepository(paths: app.paths)
        let log = try StjornarvaldPolicyLogStore(databaseURL: app.paths.stjornarvaldPolicyLogSQLite,
                                               jsonlURL: app.paths.stjornarvaldPolicyLogJSONL)
        try await waitUntil { !cache.refreshState().workerActive }
        try await waitUntil { !app.stjornarvaldObservations.metrics().workerActive }
        try fixture.writeGraph(includeWorker: true)
        let started = try wire.call(id: 1, name: "process.run", arguments: [
            "executable": "/usr/bin/true", "arguments": [], "replay_class": "read_only",
            "timeout_sec": 10,
        ])
        let job = try XCTUnwrap(started["structuredContent"] as? [String: Any])
        XCTAssertEqual(job["ok"] as? Bool, true)
        try await waitUntil { (try? log.events(limit: 10).contains { $0.type == .opened }) == true }
        let event = try XCTUnwrap(try log.events(limit: 10).first { $0.type == .opened })
        XCTAssertEqual(event.candidate.scope.projectID, context.projectID.description)
        XCTAssertEqual(event.candidate.scope.projectGeneration, Int(context.projectGeneration.rawValue))
        XCTAssertEqual(event.candidate.scope.clientID, client.rawValue)
        XCTAssertNil(event.candidate.scope.runID)
        XCTAssertEqual(event.candidate.rule.id.rawValue, "RFD-NATIVE-001")
        XCTAssertTrue(event.candidate.evidenceReferences.contains("Production/worker.py"))
        var decorated: [String: Any]?
        for id in 2..<102 where decorated == nil {
            let result = try wire.call(id: id, name: "job.list", arguments: [:])
            if (result["content"] as? [[String: Any]])?.count == 2 { decorated = result }
            if decorated == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let delivered = try XCTUnwrap(decorated)
        let content = try XCTUnwrap(delivered["content"] as? [[String: Any]])
        XCTAssertTrue((content[1]["text"] as? String)?.contains("STJORNARVALD POLICY NOTICE") == true)
        XCTAssertTrue((content[1]["text"] as? String)?.contains("Raven") == true
            || (content[1]["text"] as? String)?.contains("ed0028a") == true)
        let canonical = try app.tools.call(name: "job.list", arguments: [:], clientID: client)
        XCTAssertEqual(try JSONSupport.canonicalJSON(delivered["structuredContent"] as? [String: Any] ?? [:]),
            try JSONSupport.canonicalJSON(canonical.payload))
        let target = StjornarvaldPolicyNoticeRepository.mcpTargetIdentity(
            projectID: context.projectID.description,
            generation: Int(context.projectGeneration.rawValue), clientID: client.rawValue)
        try await waitUntil {
            (try? notices.pending(targetKind: .mcpClient, targetIdentity: target,
                maximumCount: 8, maximumBytes: 16 * 1_024).isEmpty) == true
        }
        XCTAssertTrue(try observations.recentEvaluationActivity(limit: 20).contains { $0.findingCount > 0 })

        try fixture.writeGraph(includeWorker: false)
        _ = try wire.call(id: 200, name: "job.list", arguments: [:])
        try await waitUntil { (try? log.events(limit: 10).contains { $0.type == .corrected }) == true }
        XCTAssertEqual(try log.violations(limit: 10).first?.violation.state, .corrected)
        XCTAssertFalse(cache.refreshState().pendingTargetCount > 1)
    }

    func testNativeEvidenceRetriesAfterOutboxFullAndDeduplicatesOnlyAfterDurableRetention() async throws {
        let fixture = try NativeMembershipFixture()
        defer { fixture.cleanup() }
        let app = try ForgeApp.bootstrap(home: fixture.home, startTelemetry: false)
        defer { _ = app.shutdown() }
        _ = try app.config.update(["allowed_roots": [fixture.root.path]], save: false)
        let clientID = ClientID("lm-studio:outbox-full-policy-control")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": fixture.project.path], clientID: clientID).ok)
        let context = try app.projectContexts.invocationContext(for: clientID)
        let outbox = fixture.root.appendingPathComponent("bounded-outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var fillers: [URL] = []
        for index in 0..<StjornarvaldObservationClient.maximumOutboxItems {
            let file = outbox.appendingPathComponent(String(format: "%020d-fixture.json", index))
            try Data().write(to: file)
            fillers.append(file)
        }
        let client = StjornarvaldObservationClient(transport: AlwaysUnavailableObservationTransport(),
            outboxDirectory: outbox, processID: "outbox-full-control", bootID: "boot-control")
        let producer = StjornarvaldNativeTargetObservationProducer(projectContexts: app.projectContexts)
        let emitter = StjornarvaldObservationEmitter(submitter: client, nativeTargetProducer: producer,
            shutdown: { await client.shutdown() })
        defer { XCTAssertTrue(emitter.shutdown()) }
        func ordinaryTool() -> DevelopmentObservation {
            StjornarvaldProductObservationFactory.ordinaryTool(name: "job.list",
                result: .success(["jobs": []]), context: context, clientID: clientID)
        }
        emitter.record(ordinaryTool())
        try await waitUntil { !emitter.metrics().workerActive }
        let fullCount = await client.pendingCount()
        XCTAssertEqual(fullCount, StjornarvaldObservationClient.maximumOutboxItems)

        // Remove only files created by this fixture, then repeat the unchanged graph.
        for file in fillers { try FileManager.default.removeItem(at: file) }
        emitter.record(ordinaryTool())
        try await waitUntil { !emitter.metrics().workerActive }
        let retainedCount = await client.pendingCount()
        XCTAssertEqual(retainedCount, 2)
        let retainedFiles = try FileManager.default.contentsOfDirectory(at: outbox,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observations = try retainedFiles.map { file -> DevelopmentObservation in
            let envelope = try JSONSupport.object(from: Data(contentsOf: file))
            let observation = try XCTUnwrap(envelope["observation"] as? [String: Any])
            return try decoder.decode(DevelopmentObservation.self,
                from: JSONSerialization.data(withJSONObject: observation))
        }
        let native = try XCTUnwrap(observations.first { $0.kind == .projectConfigurationObserved })
        XCTAssertEqual(native.details?.nativeTarget?.shippingRuntimePaths,
                       ["Production/App.swift", "Production/worker.py"])
        XCTAssertNil(native.scope.runID)
        XCTAssertEqual(native.scope.projectID, context.projectID.description)
        emitter.record(ordinaryTool())
        try await waitUntil { !emitter.metrics().workerActive }
        let deduplicatedCount = await client.pendingCount()
        XCTAssertEqual(deduplicatedCount, 3, "a retained graph is emitted once; later ordinary observations remain available")
    }

    func testEmitterBoundsAdmissionBecomesIdleAndStopsWithinDeadline() async throws {
        let submitter = SuspendedObservationSubmitter()
        let emitter = StjornarvaldObservationEmitter(submitter: submitter)
        let result = ToolResult.success(["value": "bounded"])

        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<2_000 {
            emitter.record(StjornarvaldProductObservationFactory.ordinaryTool(
                name: "fixture.\(index)",
                result: result,
                context: nil,
                clientID: ClientID("qualification")
            ))
        }
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        try await waitUntil { await submitter.hasStarted() }
        let saturated = emitter.metrics()
        XCTAssertLessThanOrEqual(
            saturated.pendingCount,
            StjornarvaldObservationEmitter.maximumPendingCount
        )
        XCTAssertGreaterThan(saturated.droppedCount, 0)
        XCTAssertTrue(saturated.workerActive)

        await submitter.release()
        try await waitUntil {
            let metrics = emitter.metrics()
            return metrics.pendingCount == 0 && !metrics.workerActive
        }
        XCTAssertTrue(emitter.shutdown(timeoutSeconds: 0.5))
        let stopped = emitter.metrics()
        XCTAssertFalse(stopped.accepting)
        XCTAssertFalse(stopped.workerActive)

        let blockedSubmitter = SuspendedObservationSubmitter()
        let blocked = StjornarvaldObservationEmitter(submitter: blockedSubmitter)
        blocked.record(StjornarvaldProductObservationFactory.ordinaryTool(
            name: "fixture.blocked",
            result: result,
            context: nil,
            clientID: ClientID("qualification")
        ))
        try await waitUntil { await blockedSubmitter.hasStarted() }
        let shutdownStart = clock.now
        XCTAssertFalse(blocked.shutdown(timeoutSeconds: 0.05))
        XCTAssertLessThan(shutdownStart.duration(to: clock.now), .seconds(1))
        await blockedSubmitter.release()
        try await waitUntil { !blocked.metrics().workerActive }
    }

    func testToolResultSurvivesManagerFailureAndRestartDeliversRedactedObservationOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-integration-\(UUID().uuidString)", isDirectory: true)
        let appHome = root.appendingPathComponent("home", isDirectory: true)
        let outbox = root.appendingPathComponent("client-outbox", isDirectory: true)
        let app = try ForgeApp.bootstrap(home: appHome)
        defer {
            _ = app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let unavailableClient = StjornarvaldObservationClient(
            transport: AlwaysUnavailableObservationTransport(),
            outboxDirectory: outbox,
            processID: "qualification-process",
            bootID: "boot-a"
        )
        let emitter = StjornarvaldObservationEmitter(
            submitter: unavailableClient,
            shutdown: { await unavailableClient.shutdown() }
        )
        let fixed = QualificationToolPack()
        let baseline = ToolRouter(
            app: app,
            packs: [fixed],
            observationRecorder: NoOpObservationRecorder()
        )
        let observed = ToolRouter(
            app: app,
            packs: [fixed],
            observationRecorder: emitter
        )
        let secret = "qualification-secret-that-must-not-enter-policy-state"
        let baselineResult = try baseline.call(
            name: "forge_status",
            arguments: ["secret": secret],
            clientID: ClientID("baseline-client")
        )
        let start = ContinuousClock().now
        let observedResult = try observed.call(
            name: "forge_status",
            arguments: ["secret": secret],
            clientID: ClientID("observed-client")
        )
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .seconds(1))
        XCTAssertEqual(try canonicalResult(baselineResult), try canonicalResult(observedResult))

        try await waitUntil { await unavailableClient.pendingCount() == 1 }
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(retainedFiles.count, 1)
        let retained = try String(contentsOf: XCTUnwrap(retainedFiles.first), encoding: .utf8)
        XCTAssertFalse(retained.contains(secret))
        XCTAssertFalse(retained.contains(QualificationToolPack.sensitiveResult))
        XCTAssertTrue(emitter.shutdown(timeoutSeconds: 1))

        let available = CapturingObservationTransport()
        let restarted = StjornarvaldObservationClient(
            transport: available,
            outboxDirectory: outbox,
            processID: "qualification-process",
            bootID: "boot-b"
        )
        await restarted.resume()
        try await waitUntil { await restarted.pendingCount() == 0 }
        let delivered = await available.observations()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.kind, .toolInvocationCompleted)
        XCTAssertEqual(delivered.first?.subjectIdentity, "tool:forge_status")
        XCTAssertFalse(delivered.first?.summary.contains(secret) ?? true)
        XCTAssertFalse(delivered.first?.evidenceReferences.contains(where: {
            $0.contains(secret) || $0.contains(QualificationToolPack.sensitiveResult)
        }) ?? true)
        await restarted.shutdown()
    }

    func testManagedObservationIdentityIsStableAndCarriesNoArgumentsOrResultBody() throws {
        let context = ToolInvocationContext(
            projectID: ProjectID(UUID(uuidString: "10000000-0000-4000-8000-000000000001")!),
            projectGeneration: .initial,
            clientID: ClientID("managed-client"),
            runID: RunID(UUID(uuidString: "20000000-0000-4000-8000-000000000001")!),
            providerSessionID: "session-1",
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [URL(fileURLWithPath: "/tmp/project")],
                allowedTools: ["forge_status"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let secret = "managed-secret"
        let call = BrokeredToolCall(
            providerCallID: "provider-call-1",
            toolName: "forge_status",
            arguments: ["secret": secret]
        )
        let result = ToolResult.success(["body": QualificationToolPack.sensitiveResult])
        let first = StjornarvaldProductObservationFactory.managedTool(
            call: call,
            result: result,
            context: context
        )
        let second = StjornarvaldProductObservationFactory.managedTool(
            call: call,
            result: result,
            context: context
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
        let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(QualificationToolPack.sensitiveResult))
        XCTAssertEqual(first.scope.runID, context.runID?.description)
        XCTAssertEqual(first.scope.sessionID, context.providerSessionID)
    }

    private func canonicalResult(_ result: ToolResult) throws -> String {
        try JSONSupport.canonicalJSON([
            "ok": result.ok,
            "is_error": result.isError,
            "payload": result.payload,
        ])
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else {
                XCTFail("condition timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SuspendedObservationSubmitter: PolicyObservationSubmitting {
    private var blocking = true
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func submit(_ observation: DevelopmentObservation) async {
        started = true
        if blocking {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func hasStarted() -> Bool { started }

    func release() {
        blocking = false
        continuation?.resume()
        continuation = nil
    }
}

private struct AlwaysUnavailableObservationTransport: StjornarvaldObservationTransport {
    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        throw URLError(.cannotConnectToHost)
    }
}

private actor CapturingObservationTransport: StjornarvaldObservationTransport {
    private var captured: [DevelopmentObservation] = []

    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        captured.append(contentsOf: observations)
        return StjornarvaldObservationReceiptBatch(
            receipts: observations.map {
                StjornarvaldObservationSubmissionReceipt(
                    observationID: $0.id,
                    state: .persisted,
                    sequence: 1
                )
            },
            developmentContinues: true
        )
    }

    func observations() -> [DevelopmentObservation] { captured }
}

private struct NoOpObservationRecorder: StjornarvaldObservationRecording {
    func record(_ observation: DevelopmentObservation) {}
}

private struct QualificationToolPack: ToolPackHandling {
    static let sensitiveResult = "sensitive-result-body"
    let toolNames = ["forge_status"]

    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard name == "forge_status" else { return nil }
        return .success(["status": "unchanged", "body": Self.sensitiveResult])
    }
}

private final class NativeMembershipCountingClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private let origin = Date(timeIntervalSince1970: 1_000)
    private let expiringAfterReads: Int?
    private var reads = 0

    init(expiringAfterReads: Int? = nil) { self.expiringAfterReads = expiringAfterReads }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        if let expiringAfterReads, reads > expiringAfterReads {
            return origin.addingTimeInterval(3)
        }
        return origin
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

private final class NativeMembershipFixture {
    let root: URL
    let project: URL
    let home: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stj-native-\(UUID())")
        project = root.appendingPathComponent("project")
        home = root.appendingPathComponent("home")
        for path in ["Production/App.swift", "Production/worker.py", "Production/Support/analysis.py",
                     "Tests/test-worker.py", "Build/build-helper.sh"] {
            let file = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        try writeGraph()
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func writeSharedPhaseGraph() throws {
        try mutateGraph { objects in
            let targetIDs = (0..<8).map { "APP_\($0)" }
            var target = objects["APP"] ?? [:]
            target["buildPhases"] = ["SOURCES"]
            for id in targetIDs { objects[id] = target }
            objects["ROOT"]?["targets"] = targetIDs
            objects["SOURCES"]?["files"] = Array(repeating: "BUILD_SWIFT", count: 8192)
        }
    }
    func mutateGraph(_ mutation: (inout [String: [String: Any]]) -> Void) throws {
        let file = project.appendingPathComponent("Fixture.xcodeproj/project.pbxproj")
        var graph = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: file),
            format: nil) as? [String: Any])
        var objects = try XCTUnwrap(graph["objects"] as? [String: [String: Any]])
        mutation(&objects)
        graph["objects"] = objects
        try PropertyListSerialization.data(fromPropertyList: graph, format: .xml, options: 0)
            .write(to: file, options: .atomic)
    }
    func writeGraph(synchronized: Bool = false, unsupportedException: Bool = false,
                    includeWorker: Bool = true) throws {
        var objects: [String: [String: Any]] = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "GROUP", "targets": ["APP", "TEST"]],
            "GROUP": ["isa": "PBXGroup", "sourceTree": "<group>", "children": ["PRODUCTION", "SWIFT", "PYTHON", "TESTFILE"]],
            "PRODUCTION": ["isa": "PBXFileSystemSynchronizedRootGroup", "sourceTree": "<group>",
                           "path": "Production", "exceptions": ["EXCEPTION"]],
            "SWIFT": ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Production/App.swift"],
            "PYTHON": ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Production/worker.py"],
            "TESTFILE": ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "Tests/test-worker.py"],
            "BUILD_SWIFT": ["isa": "PBXBuildFile", "fileRef": "SWIFT"],
            "BUILD_PYTHON": ["isa": "PBXBuildFile", "fileRef": "PYTHON"],
            "BUILD_TEST": ["isa": "PBXBuildFile", "fileRef": "TESTFILE"],
            "SOURCES": ["isa": "PBXSourcesBuildPhase", "files": synchronized ? [] : ["BUILD_SWIFT"]],
            "RESOURCES": ["isa": "PBXResourcesBuildPhase", "files": synchronized || !includeWorker ? [] : ["BUILD_PYTHON"]],
            "AUTOMATION": ["isa": "PBXShellScriptBuildPhase", "inputPaths": ["$(SRCROOT)/Build/build-helper.sh"],
                           "shellScript": "$(SRCROOT)/Build/build-helper.sh"],
            "TEST_SOURCES": ["isa": "PBXSourcesBuildPhase", "files": ["BUILD_TEST"]],
            "APP": ["isa": "PBXNativeTarget", "name": "FixtureApp",
                    "productType": "com.apple.product-type.application",
                    "buildPhases": ["SOURCES", "RESOURCES", "AUTOMATION"],
                    "fileSystemSynchronizedGroups": synchronized ? ["PRODUCTION"] : []],
            "TEST": ["isa": "PBXNativeTarget", "name": "FixtureTests",
                     "productType": "com.apple.product-type.bundle.unit-test", "buildPhases": ["TEST_SOURCES"]],
            "EXCEPTION": ["isa": "PBXFileSystemSynchronizedBuildFileExceptionSet", "target": "APP",
                          "membershipExceptions": ["Support/analysis.py"]],
        ]
        if unsupportedException { objects["EXCEPTION"]?["additionalCompilerFlagsByRelativePath"] = ["App.swift": "-DOTHER"] }
        let graph: [String: Any] = ["archiveVersion": 1, "objectVersion": 77, "rootObject": "ROOT", "objects": objects]
        let directory = project.appendingPathComponent("Fixture.xcodeproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: graph, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("project.pbxproj"), options: .atomic)
    }
}

private final class PolicyNoticeWire: @unchecked Sendable {
    private let server: MCPServer
    private let input = Pipe()
    private let output = Pipe()
    private let finished = DispatchSemaphore(value: 0)
    private let errorLock = NSLock()
    private var error: Error?
    private var buffer = Data()
    init(server: MCPServer) { self.server = server }
    func start() {
        DispatchQueue(label: "forge.test.policy-wire").async { [self] in
            do { try server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
            catch { errorLock.lock(); self.error = error; errorLock.unlock() }
            finished.signal()
        }
    }
    func stop() -> Error? {
        try? input.fileHandleForWriting.close()
        let completed = finished.wait(timeout: .now() + 5) == .success
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        errorLock.lock()
        defer { errorLock.unlock() }
        return completed ? error : WireError.timeout
    }
    func call(id: Int, name: String, arguments: [String: Any]) throws -> [String: Any] {
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                let response = try JSONSupport.object(from: line)
                guard response["id"] as? Int == id,
                      let result = response["result"] as? [String: Any] else { throw WireError.response }
                return result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
            guard Darwin.poll(&descriptor, 1, milliseconds) > 0 else { throw WireError.timeout }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw WireError.response }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw WireError.response }
        }
        throw WireError.timeout
    }
    private enum WireError: Error { case timeout, response }
}

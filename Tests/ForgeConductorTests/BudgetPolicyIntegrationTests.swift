import Foundation
import XCTest
import Darwin
@testable import ForgeConductorCore

extension XCTestCase {
    /// These attachments retain observations from the associated native test.
    /// SwiftPM execution does not substitute for an xcresult qualification artifact.
    func retainBudgetEffects(caseID: String, effects: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "case_id": caseID,
            "execution_mode": "native_in_process", "effects": effects,
        ], options: [.sortedKeys])
        guard data.count <= 1_048_576 else { throw BudgetIntegrationFailure.evidenceTooLarge }
        #if !SWIFT_PACKAGE
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = caseID + "-effects.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }
}

final class BudgetPolicyIntegrationTests: XCTestCase {
    func testInvalidBudgetRelationshipsAreRejectedByAuthenticatedManagerRouteWithoutMutation() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let graph = try BudgetIntegrationOwnerGraph(home: home, port: availablePort())
        defer { _ = graph.shutdown() }
        let client = try graph.client()
        let originalPolicy = try await client.budgetPolicy(scope: .globalDefault)
        let originalConfig = try Data(contentsOf: graph.paths.configJSON)
        let originalPolicySHA = try encodedSHA(originalPolicy)
        let fixtures: [(BudgetContextPolicy, String, String, String)] = [
            (.init(mode: .manual, maxContextTokens: 4_096, responseReserveTokens: 4_096),
             "context.reserves", "reserves_must_leave_input_capacity", "0..<4096"),
            (.init(checkpointRatio: 0.9, rolloverRatio: 0.8, emergencyRatio: 0.95),
             "context.thresholds", "expected_ordered_admitted_total_ratios", "0 < checkpoint < rollover < emergency <= 1"),
            (.init(checkpointRatio: 0.7, rolloverRatio: 0.8, emergencyRatio: 1.01),
             "context.thresholds", "expected_ordered_admitted_total_ratios", "0 < checkpoint < rollover < emergency <= 1"),
        ]
        var observations: [[String: Any]] = []
        for (context, field, reason, range) in fixtures {
            // Encode directly so the malformed policy reaches the HTTP mutation
            // boundary instead of being rejected by the typed client's preflight.
            let request = BudgetPolicyUpdate(scope: .globalDefault, expectedRevision: originalPolicy.revision,
                expectedGlobalRevision: originalPolicy.globalRevision, operation: .set,
                policy: BudgetPolicy(context: context))
            let update = try JSONSupport.object(from: JSONEncoder().encode(request))
            let result = try await postSettings(["settings": ["budget_update": update]], graph: graph)
            XCTAssertEqual(result.status, 400)
            XCTAssertEqual(result.object["code"] as? String, "invalid_settings")
            XCTAssertEqual(result.object["field"] as? String, field)
            XCTAssertEqual(result.object["reason"] as? String, reason)
            XCTAssertEqual(result.object["permitted_range"] as? String, range)
            let current = try await client.budgetPolicy(scope: .globalDefault)
            let currentBytes = try Data(contentsOf: graph.paths.configJSON)
            XCTAssertEqual(current, originalPolicy)
            XCTAssertEqual(currentBytes, originalConfig)
            observations.append([
                "request": update, "status": result.status, "response": result.object,
                "expected_field": field, "expected_reason": reason, "expected_range": range,
                "current_policy_sha256": try encodedSHA(current),
                "current_config_sha256": JSONSupport.sha256Hex(currentBytes),
            ])
        }
        let status = try await client.status()
        XCTAssertTrue(status.httpListening)
        try retainBudgetEffects(caseID: "T03-02", effects: [
            "original_policy_sha256": originalPolicySHA,
            "original_config_sha256": JSONSupport.sha256Hex(originalConfig),
            "requests": observations, "service_active_after_errors": status.httpListening,
        ])
    }

    func testMalformedStoredBudgetKeepsBootstrappedManagerRecoverableAndAvailable() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let port = try availablePort()
        var original = AppConfig.default.asDictionary()
        original["dashboard"] = ["host": "127.0.0.1", "port": port, "refresh_interval_sec": 8]
        original["shell"] = ["enabled": false, "user_disabled": true, "policy_version": 2,
                             "policy_origin": "user_disabled", "default_timeout_sec": 47] as [String: Any]
        original["log_level"] = "debug"
        original["allowed_roots"] = [home.path]
        original["unrelated_extension"] = ["preserve": "malformed-budget-fixture"]
        var state = try JSONSupport.object(from: JSONEncoder().encode(BudgetPolicyState.default))
        var policy = try XCTUnwrap(state["global_policy"] as? [String: Any])
        var context = try XCTUnwrap(policy["context"] as? [String: Any])
        context["max_context_tokens"] = 0
        policy["context"] = context; state["global_policy"] = policy
        original["budget_policy"] = state
        let originalBytes = try JSONSupport.data(from: original)
        try originalBytes.write(to: paths.configJSON, options: .atomic)

        // This constructor performs a real ForgeApp bootstrap, CLU startup,
        // and ManagerNode listener startup against the malformed durable file.
        let graph = try BudgetIntegrationOwnerGraph(home: home, port: port, configurePort: false)
        defer { _ = graph.shutdown() }
        let client = try graph.client()
        let settings = try await client.settings()
        let status = try await client.status()
        XCTAssertTrue(status.httpListening)
        XCTAssertNil(settings.budgetPolicy)
        let issue = try XCTUnwrap(settings.budgetPolicyIssue)
        XCTAssertTrue(issue.contains("context.max_context_tokens"))
        XCTAssertEqual(settings.logLevel, "debug")
        XCTAssertFalse(settings.shellEnabled)
        XCTAssertTrue(settings.shellUserDisabled)
        XCTAssertEqual(settings.shellTimeoutSec, 47)
        XCTAssertEqual(settings.allowedRoots, [home.path])
        XCTAssertNotNil(try graph.application().config.budgetPolicyError)
        let persisted = try Data(contentsOf: paths.configJSON)
        XCTAssertEqual(persisted, originalBytes)
        let backupURL = paths.configMigrationsDir.appendingPathComponent(
            "config.pre-budget-v1." + JSONSupport.sha256Hex(originalBytes) + ".json")
        let backup = try Data(contentsOf: backupURL)
        XCTAssertEqual(backup, originalBytes)
        let retainedObject = try JSONSupport.object(from: persisted)
        let unrelated = try XCTUnwrap(retainedObject["unrelated_extension"] as? [String: Any])
        XCTAssertEqual(unrelated["preserve"] as? String, "malformed-budget-fixture")
        try retainBudgetEffects(caseID: "T03-06", effects: [
            "original_config_sha256": JSONSupport.sha256Hex(originalBytes),
            "current_config_sha256": JSONSupport.sha256Hex(persisted),
            "backup_sha256": JSONSupport.sha256Hex(backup), "backup_filename": backupURL.lastPathComponent,
            "budget_policy_available": settings.budgetPolicy != nil, "budget_policy_issue": issue,
            "shell_enabled": settings.shellEnabled, "shell_user_disabled": settings.shellUserDisabled,
            "shell_timeout_sec": settings.shellTimeoutSec, "log_level": settings.logLevel,
            "allowed_roots": settings.allowedRoots, "unrelated_extension": unrelated,
            "service_active_after_errors": status.httpListening,
            "managed_runtime_started": graph.references.runtime != nil,
        ])
    }

    func testCompleteOwnerGraphRestartPreservesRequestedAndRuntimeEffectiveBudgetPolicies() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let port = try availablePort()
        var first: BudgetIntegrationOwnerGraph? = try BudgetIntegrationOwnerGraph(home: home, port: port)
        defer { _ = first?.shutdown() }
        let references = try XCTUnwrap(first?.references)
        let projects = try await registerProjects(graph: XCTUnwrap(first), home: home)
        let initialClient = try XCTUnwrap(first).client()
        let globalPolicy = BudgetPolicy(context: .init(mode: .manual, maxContextTokens: 12_288),
                                        tools: .init(callsPerSession: 48), automaticHandoffEnabled: true)
        _ = try await initialClient.updateSettings(.init(budgetPolicyUpdate: .init(scope: .globalDefault,
            expectedRevision: 1, expectedGlobalRevision: 1, operation: .set, policy: globalPolicy)))
        let overridePolicy = BudgetPolicy(context: .init(mode: .manual, maxContextTokens: 8_192),
                                          tools: .init(callsPerSession: 24))
        _ = try await initialClient.updateSettings(.init(budgetPolicyUpdate: .init(scope: projects[1].scope,
            expectedRevision: 0, expectedGlobalRevision: 2, operation: .set, policy: overridePolicy)))
        _ = try await initialClient.updateSettings(.init(budgetPolicyUpdate: .init(scope: projects[2].scope,
            expectedRevision: 0, expectedGlobalRevision: 2, operation: .set, policy: overridePolicy)))
        _ = try await initialClient.updateSettings(.init(budgetPolicyUpdate: .init(scope: projects[2].scope,
            expectedRevision: 1, expectedGlobalRevision: 2, operation: .inherit)))

        let beforeSettings = try await initialClient.settings()
        let beforeState = try XCTUnwrap(beforeSettings.budgetPolicy)
        let beforeConfig = try Data(contentsOf: AppPaths(home: home).configJSON)
        let beforeRuntime = try await exerciseRuntimePolicies(graph: XCTUnwrap(first), projects: projects)
        let shutdown = try XCTUnwrap(first).shutdown()
        XCTAssertTrue(shutdown.completed)
        first = nil
        let releaseDeadline = ContinuousClock.now + .seconds(5)
        while !references.allReleased, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(references.allReleased, "Every original app, manager, runtime and repository owner must be released")

        let second = try BudgetIntegrationOwnerGraph(home: home, port: port, configurePort: false)
        defer { _ = second.shutdown() }
        let restartedClient = try second.client()
        let afterSettings = try await restartedClient.settings()
        let afterState = try XCTUnwrap(afterSettings.budgetPolicy)
        XCTAssertEqual(afterState, beforeState)
        let afterConfig = try Data(contentsOf: second.paths.configJSON)
        XCTAssertEqual(afterConfig, beforeConfig)
        let global = try await restartedClient.budgetPolicy(scope: .globalDefault)
        XCTAssertEqual(global.revision, 2)
        XCTAssertEqual(global.policy, globalPolicy)
        let override = try await restartedClient.budgetPolicy(scope: projects[1].scope)
        XCTAssertEqual(override.revision, 1)
        XCTAssertFalse(override.inherited)
        XCTAssertEqual(override.policy, overridePolicy)
        let inherited = try await restartedClient.budgetPolicy(scope: projects[2].scope)
        XCTAssertEqual(inherited.revision, 2)
        XCTAssertTrue(inherited.inherited)
        XCTAssertEqual(inherited.policy, globalPolicy)
        let afterRuntime = try await exerciseRuntimePolicies(graph: second, projects: projects)
        for (before, after) in zip(beforeRuntime, afterRuntime) {
            XCTAssertEqual(before.selection, after.selection)
            XCTAssertEqual(before.effectiveContextTokens, after.effectiveContextTokens)
        }
        try retainBudgetEffects(caseID: "T03-04", effects: [
            "execution_mode": "full_owner_graph", "restart_mode": "full_owner_graph",
            "application_scope": "ForgeApp_core", "native_gui_relaunched": false,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "provider_measurement_scope": "deterministic_fixture", "provider_loaded_capacity_fixture": 16_384,
            "before_requested_state": try object(beforeState), "after_requested_state": try object(afterState),
            "before_config_sha256": JSONSupport.sha256Hex(beforeConfig),
            "after_config_sha256": JSONSupport.sha256Hex(afterConfig),
            "before_runtime_effective": try beforeRuntime.map(object),
            "after_runtime_effective": try afterRuntime.map(object),
            "first_shutdown_completed": shutdown.completed,
            "released_owners": references.releaseEvidence,
            "second_managed_runtime_started": second.references.runtime != nil,
        ])
    }

    private func exerciseRuntimePolicies(graph: BudgetIntegrationOwnerGraph,
                                         projects: [BudgetIntegrationProject]) async throws -> [ResolvedContextBudgetPolicy] {
        var results: [ResolvedContextBudgetPolicy] = []
        for project in projects {
            let runID = RunID()
            _ = try graph.manager().startAutonomousRun(runID: runID, projectID: project.id,
                expectedGeneration: .init(1), mission: "Observe the saved budget in a bounded deterministic provider turn",
                providerID: BudgetIntegrationProvider.identifier, adapterID: BudgetIntegrationProvider.adapterID,
                modelKey: BudgetIntegrationProvider.modelKey, allowedTools: ["fs_read"],
                completionGates: ["budget_fixture_completion"])
            let repository = try graph.application().projectContexts.repository
            let deadline = ContinuousClock.now + .seconds(10)
            var observation: ContextBudgetObservation?
            while ContinuousClock.now < deadline {
                if let run = try await repository.autonomousRun(runID),
                   let sessionID = run.activeSessionID, run.state == .blockedConfiguration {
                    let identity = ContextBudgetIdentity(runID: runID, projectID: project.id,
                        projectGeneration: .init(1), sessionID: sessionID)
                    observation = try await repository.latestContextBudgetObservation(identity: identity)
                    if observation?.triggerPoint == .afterProviderTurn { break }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let effect = try XCTUnwrap(observation, "The real manager-owned run must retain its provider boundary")
            XCTAssertEqual(effect.triggerPoint, .afterProviderTurn)
            let resolved = try XCTUnwrap(effect.accounting?.resolvedPolicy)
            let requested = try await graph.client().budgetPolicy(scope: project.scope)
            XCTAssertEqual(resolved.selection, requested)
            XCTAssertEqual(resolved.verifiedLoadedContextTokens, 16_384)
            XCTAssertEqual(resolved.effectiveContextTokens, requested.policy.context.maxContextTokens)
            XCTAssertEqual(effect.accounting?.rawProviderUsage?.inputTokens, 500)
            results.append(resolved)
        }
        return results
    }

    private func registerProjects(graph: BudgetIntegrationOwnerGraph, home: URL) async throws -> [BudgetIntegrationProject] {
        _ = try graph.application().config.update(["allowed_roots": [home.path]])
        var projects: [BudgetIntegrationProject] = []
        for label in ["global-inherited", "project-override", "project-tombstone"] {
            let root = home.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = ProjectID()
            _ = try await graph.application().projectContexts.repository.registerProjectUnchecked(
                projectID: id, displayName: label, canonicalRoot: root)
            projects.append(BudgetIntegrationProject(id: id))
        }
        return projects
    }

    private func postSettings(_ object: [String: Any], graph: BudgetIntegrationOwnerGraph) async throws -> (status: Int, object: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(graph.port)/api/manager/settings")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try ManagerControlCredentialStore(paths: graph.paths).bearerToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSupport.data(from: object)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 65_536, let response = response as? HTTPURLResponse else {
            throw BudgetIntegrationFailure.invalidResponse
        }
        return (response.statusCode, try JSONSupport.object(from: data))
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-test-budget-integration-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    private func availablePort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BudgetIntegrationFailure.portUnavailable }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BudgetIntegrationFailure.portUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { throw BudgetIntegrationFailure.portUnavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSupport.object(from: JSONEncoder().encode(value))
    }
    private func encodedSHA<T: Encodable>(_ value: T) throws -> String {
        try JSONSupport.sha256Hex(JSONSupport.data(from: object(value)))
    }
}

private enum BudgetIntegrationFailure: Error { case invalidResponse, portUnavailable, ownerClosed, evidenceTooLarge }

private struct BudgetIntegrationProject {
    let id: ProjectID
    var scope: BudgetPolicyScope { .init(kind: .projectOverride, projectID: id.description, projectGeneration: 1) }
}

private final class BudgetIntegrationOwnerReferences: @unchecked Sendable {
    weak var app: ForgeApp?
    weak var manager: ManagerNode?
    weak var runtime: ManagedAutonomyRuntime?
    weak var repository: ProjectControlPlaneRepository?
    var allReleased: Bool { app == nil && manager == nil && runtime == nil && repository == nil }
    var releaseEvidence: [String: Bool] {
        ["app": app == nil, "manager": manager == nil, "managed_runtime": runtime == nil, "repository": repository == nil]
    }
}

private final class BudgetIntegrationOwnerGraph {
    let paths: AppPaths
    let port: Int
    let references = BudgetIntegrationOwnerReferences()
    private var app: ForgeApp?
    private var node: ManagerNode?

    init(home: URL, port: Int, configurePort: Bool = true) throws {
        paths = AppPaths(home: home); self.port = port
        let application = try ForgeApp.bootstrap(home: home)
        app = application; references.app = application; references.repository = application.projectContexts.repository
        do {
            if configurePort { _ = try application.config.update(["dashboard": ["port": port]]) }
            let registry = BudgetIntegrationProvider.registry()
            let references = self.references
            let manager = ManagerNode(app: application, managedAutonomyFactory: { application in
                let runtime = try ManagedAutonomyRuntime(app: application, registry: registry)
                references.runtime = runtime
                return runtime
            })
            node = manager; references.manager = manager
            _ = try manager.recoverManagedAutonomy()
            _ = try manager.startService()
        } catch {
            _ = shutdown()
            throw error
        }
    }

    func application() throws -> ForgeApp {
        guard let app else { throw BudgetIntegrationFailure.ownerClosed }; return app
    }
    func manager() throws -> ManagerNode {
        guard let node else { throw BudgetIntegrationFailure.ownerClosed }; return node
    }
    func client() throws -> ManagerDashboardClient {
        _ = try manager()
        return ManagerDashboardClient(host: "127.0.0.1", port: port,
            credentials: ManagerControlCredentialStore(paths: paths))
    }
    @discardableResult func shutdown() -> RuntimeJobShutdownReport {
        node?.shutdownManagedAutonomy()
        _ = try? node?.stopService()
        node = nil
        let report = app?.shutdown() ?? RuntimeJobShutdownReport(completed: true, unresolvedJobIDs: [], persistencePendingJobIDs: [])
        app = nil
        return report
    }
}

/// Deterministic transport inputs exercise the real manager/runtime evaluator.
/// These capabilities and counters are fixture data, never live-provider proof.
private actor BudgetIntegrationProvider: ManagedModelProvider {
    static let identifier = "budget-integration-provider"
    static let adapterID = "budget-integration-adapter"
    static let modelKey = "budget-integration-model"
    nonisolated let providerID = identifier
    private var receipts: [String: ProviderTurn] = [:]

    static func registry() -> HostAdapterRegistry {
        let provider = BudgetIntegrationProvider()
        let registry = HostAdapterRegistry()
        registry.register(manifest: HostPluginManifest(identifier: adapterID, version: "1", minimumContractVersion: 2,
            hostType: "deterministic-fixture", capabilities: HostCapabilities(create: false, bootstrap: false,
                usageReporting: true, resume: false, idempotency: true, queryByIdempotencyKey: true),
            configurationKeys: [], privacyRequirements: [], migrationVersion: 1),
            managedProviderFactory: { _ in provider }, factory: { _ in BudgetIntegrationUnavailableAdapter() })
        return registry
    }
    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(providerID: providerID, providerVersion: "deterministic-fixture-1",
            modelKey: Self.modelKey, providerInstanceID: "budget-integration-instance", contextLength: 16_384,
            maximumContextLength: 32_768, statefulResponses: true, streaming: true, customTools: true,
            mcp: false, structuredOutput: false, usageReporting: true, idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "d", count: 64))
    }
    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        try turn(idempotencyKey: request.idempotencyKey, previousResponseID: nil)
    }
    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        try turn(idempotencyKey: request.idempotencyKey, previousResponseID: request.previousResponseID)
    }
    func lookup(idempotencyKey: String) async throws -> ProviderTurn? { receipts[idempotencyKey] }
    func cancel(requestID: String) async {}
    private func turn(idempotencyKey: String, previousResponseID: String?) throws -> ProviderTurn {
        if let receipt = receipts[idempotencyKey] { return receipt }
        guard receipts.count < 16 else { throw BudgetIntegrationFailure.evidenceTooLarge }
        let suffix = JSONSupport.sha256Hex(idempotencyKey)
        let turn = try ProviderTurn(requestID: "budget-request-" + suffix, responseID: "budget-response-" + suffix,
            previousResponseID: previousResponseID, providerID: providerID, providerVersion: "deterministic-fixture-1",
            modelKey: Self.modelKey, providerInstanceID: "budget-integration-instance",
            messages: ["{\"forge_run_status\":\"completion_requested\",\"summary\":\"The deterministic policy observation is retained\"}"],
            toolCalls: [], usage: try ProviderUsage(capacity: 16_384, inputTokens: 500, outputTokens: 16,
                                                  source: .providerExact, confidence: 1),
            completed: true, finishReason: .stop)
        receipts[idempotencyKey] = turn
        return turn
    }
}

private struct BudgetIntegrationUnavailableAdapter: SessionHostAdapter {
    let identifier = BudgetIntegrationProvider.adapterID
    let version = "1"
    func capabilities() async throws -> HostCapabilities {
        HostCapabilities(create: false, bootstrap: false, usageReporting: false, resume: false,
                         idempotency: true, queryByIdempotencyKey: true)
    }
    func createSession(_ request: SessionCreationRequest) async throws -> HostSession { throw ContinuityRunError.hostCapabilityUnavailable }
    func session(forIdempotencyKey key: String) async throws -> HostSession? { nil }
    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws { throw ContinuityRunError.hostCapabilityUnavailable }
    func awaitAcknowledgement(session: HostSession, handoffID: String, timeout: Duration) async throws -> HandoffAcknowledgement {
        throw ContinuityRunError.hostCapabilityUnavailable
    }
    func cancel(operationID: String) async {}
}

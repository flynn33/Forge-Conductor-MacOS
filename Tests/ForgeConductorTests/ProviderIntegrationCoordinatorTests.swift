import XCTest
@testable import ForgeConductorCore

private enum FixtureProviderFailure: Error {
    case rejected
}

private struct FixtureProviderConfigurationService: ProviderConfigurationServicing {
    let snapshot: ProviderConfigurationSnapshot

    func read() async throws -> ProviderConfigurationSnapshot { snapshot }
    func update(_ request: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        _ = request
        throw FixtureProviderFailure.rejected
    }
    func models() async throws -> ProviderModelInventory {
        ProviderModelInventory(revision: snapshot.revision, models: [])
    }
}

private enum FixtureProviderBehavior: Sendable {
    case ready
    case readyDrifted
    case provisioned
    case failed
    case awaitingUserAction
    case awaitingInspectionThenRepaired
    case slow
    case uncooperative
    case blockedInspection
}

private final class ProviderAdmissionTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var opened = false

    func enterAndWait(timeout: TimeInterval = 5) throws {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(timeout)
        while !opened {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "ProviderIntegrationCoordinatorTests.InstructionAdmission",
                    code: 1
                )
            }
        }
    }

    func isEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ProviderAdmissionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func record() {
        lock.lock()
        observed = true
        lock.unlock()
    }

    func isObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }
}

private actor FixtureProviderAdapter: ProviderIntegrationAdapting {
    nonisolated let providerID: ProviderIntegrationID
    private var behavior: FixtureProviderBehavior
    private var inspectionContinuation: CheckedContinuation<Void, Never>?
    private var provisionContinuation: CheckedContinuation<Void, Never>?
    private var inspectionCallCount = 0
    private var activeInspectionCount = 0
    private var maximumActiveInspectionCount = 0
    private(set) var cancellationCount = 0
    private(set) var removalCount = 0

    init(
        providerID: ProviderIntegrationID,
        behavior: FixtureProviderBehavior = .provisioned
    ) {
        self.providerID = providerID
        self.behavior = behavior
    }

    func setBehavior(_ behavior: FixtureProviderBehavior) {
        self.behavior = behavior
    }

    func releaseInspection() {
        inspectionContinuation?.resume()
        inspectionContinuation = nil
    }

    func inspectionStats() -> (calls: Int, maximumActive: Int) {
        (inspectionCallCount, maximumActiveInspectionCount)
    }

    func releaseProvision() {
        provisionContinuation?.resume()
        provisionContinuation = nil
    }

    func inspect(operationID: String) async throws -> ProviderIntegrationInspection {
        _ = operationID
        inspectionCallCount += 1
        activeInspectionCount += 1
        maximumActiveInspectionCount = max(
            maximumActiveInspectionCount,
            activeInspectionCount
        )
        defer { activeInspectionCount -= 1 }
        if behavior == .blockedInspection {
            await withCheckedContinuation { continuation in
                inspectionContinuation = continuation
            }
        }
        if behavior == .ready || behavior == .readyDrifted {
            return try ProviderIntegrationInspection(
                state: .ready,
                detail: "Existing fixture integration is ready.",
                receipt: receipt(
                    artifactVersion: behavior == .readyDrifted
                        ? "fixture-v2" : "fixture-v1"
                )
            )
        }
        if behavior == .awaitingInspectionThenRepaired {
            return try ProviderIntegrationInspection(
                state: .awaitingUserAction,
                detail: "Retry host activation.",
                receipt: receipt()
            )
        }
        return try ProviderIntegrationInspection(
            state: .requiresProvisioning,
            detail: "Fixture integration requires provisioning."
        )
    }

    func provision(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        _ = request
        switch behavior {
        case .failed:
            throw FixtureProviderFailure.rejected
        case .awaitingUserAction:
            return try ProviderIntegrationAdapterResult(
                state: .awaitingUserAction,
                detail: "Approve the fixture host trust prompt.",
                receipt: receipt()
            )
        case .slow:
            try await Task.sleep(for: .seconds(30))
            return try ProviderIntegrationAdapterResult(
                state: .ready,
                detail: "Fixture integration installed.",
                receipt: receipt()
            )
        case .uncooperative:
            await withCheckedContinuation { continuation in
                provisionContinuation = continuation
            }
            return try ProviderIntegrationAdapterResult(
                state: .ready,
                detail: "Fixture integration installed.",
                receipt: receipt()
            )
        case .ready, .readyDrifted, .provisioned,
             .awaitingInspectionThenRepaired, .blockedInspection:
            return try ProviderIntegrationAdapterResult(
                state: .ready,
                detail: "Fixture integration installed.",
                receipt: receipt()
            )
        }
    }

    func repair(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        try await provision(request)
    }

    func remove(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationRemovalResult {
        _ = request
        removalCount += 1
        if behavior == .failed { throw FixtureProviderFailure.rejected }
        return try ProviderIntegrationRemovalResult(
            state: .ready,
            detail: "Fixture integration removed."
        )
    }

    func cancel(operationID: String) async {
        _ = operationID
        cancellationCount += 1
    }

    private func receipt(
        artifactVersion: String = "fixture-v1"
    ) throws -> ProviderIntegrationReceipt {
        let timestamp = ISO8601.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        return try ProviderIntegrationReceipt(
            providerID: providerID,
            artifactVersion: artifactVersion,
            installedAt: timestamp,
            verifiedAt: timestamp,
            metadata: ["fixture": "true"]
        )
    }
}

final class ProviderIntegrationCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-integrations-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testProviderSwitchIsMutuallyExclusiveAndRetainsReceipts() async throws {
        let claude = FixtureProviderAdapter(providerID: .claudeDesktop)
        let codex = FixtureProviderAdapter(providerID: .codexDesktop)
        let coordinator = try makeCoordinator(adapters: [claude, codex])

        let initial = await coordinator.snapshot()
        XCTAssertEqual(initial.selectedProviderID, .lmStudio)
        let claudeOperation = try await coordinator.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "select-claude"
        ))
        let claudeTerminal = try await coordinator.waitForOperation(
            operationID: claudeOperation.operationID
        )
        XCTAssertEqual(claudeTerminal.phase, .active)

        let afterClaude = await coordinator.snapshot()
        XCTAssertEqual(afterClaude.selectedProviderID, .claudeDesktop)
        let codexOperation = try await coordinator.select(.init(
            expectedRevision: afterClaude.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "select-codex"
        ))
        _ = try await coordinator.waitForOperation(operationID: codexOperation.operationID)

        let final = await coordinator.snapshot()
        XCTAssertEqual(final.selectedProviderID, .codexDesktop)
        XCTAssertEqual(final.providers.filter { $0.descriptor.id == .codexDesktop }.first?.setupState, .configured)
        XCTAssertEqual(final.providers.filter { $0.descriptor.id == .claudeDesktop }.first?.setupState, .configured)
        XCTAssertEqual(final.providers.filter {
            $0.descriptor.id == final.selectedProviderID
        }.count, 1)
    }

    func testCompareAndSwapRejectsStaleRevision() async throws {
        let claude = FixtureProviderAdapter(providerID: .claudeDesktop)
        let coordinator = try makeCoordinator(adapters: [claude])
        let initial = await coordinator.snapshot()

        do {
            _ = try await coordinator.select(.init(
                expectedRevision: "stale-revision",
                providerID: .claudeDesktop,
                idempotencyKey: "stale-cas"
            ))
            XCTFail("A stale selection revision must fail closed.")
        } catch let error as ProviderIntegrationError {
            guard case .revisionConflict(let expected, let actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "stale-revision")
            XCTAssertEqual(actual, initial.selectionRevision)
        }
        let final = await coordinator.snapshot()
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
    }

    func testIdempotentReplayReturnsOriginalTerminalOperation() async throws {
        let claude = FixtureProviderAdapter(providerID: .claudeDesktop)
        let coordinator = try makeCoordinator(adapters: [claude])
        let initial = await coordinator.snapshot()
        let request = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "idempotent-selection"
        )

        let accepted = try await coordinator.select(request)
        let terminal = try await coordinator.waitForOperation(operationID: accepted.operationID)
        let replay = try await coordinator.select(request)

        XCTAssertEqual(replay, terminal)
        let replaySnapshot = await coordinator.snapshot()
        XCTAssertEqual(replaySnapshot.recentOperations.count, 1)

        do {
            _ = try await coordinator.select(.init(
                expectedRevision: initial.selectionRevision,
                providerID: nil,
                idempotencyKey: "idempotent-selection"
            ))
            XCTFail("Divergent reuse of an idempotency key must fail closed.")
        } catch let error as ProviderIntegrationError {
            XCTAssertEqual(error, .idempotencyConflict)
        }
    }

    func testProvisioningFailureRollsBackToPriorSelection() async throws {
        let claude = FixtureProviderAdapter(
            providerID: .claudeDesktop,
            behavior: .failed
        )
        let coordinator = try makeCoordinator(adapters: [claude])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "failure-rollback"
        ))
        let terminal = try await coordinator.waitForOperation(operationID: accepted.operationID)

        XCTAssertEqual(terminal.phase, .failedRecoverable)
        let final = await coordinator.snapshot()
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
        XCTAssertEqual(final.selectionRevision, initial.selectionRevision)
    }

    func testAwaitingUserActionRetainsSelectionAndPartialReceipt() async throws {
        let codex = FixtureProviderAdapter(
            providerID: .codexDesktop,
            behavior: .awaitingUserAction
        )
        let coordinator = try makeCoordinator(adapters: [codex])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "await-user"
        ))
        let terminal = try await coordinator.waitForOperation(operationID: accepted.operationID)

        XCTAssertEqual(terminal.phase, .awaitingUserAction)
        let final = await coordinator.snapshot()
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
        XCTAssertEqual(final.selectionRevision, initial.selectionRevision)
        XCTAssertEqual(final.providers.first {
            $0.descriptor.id == .codexDesktop
        }?.setupState, .configured)
    }

    func testRepairRetriesAnIntegrationAwaitingUserAction() async throws {
        let codex = FixtureProviderAdapter(
            providerID: .codexDesktop,
            behavior: .awaitingInspectionThenRepaired
        )
        let coordinator = try makeCoordinator(adapters: [codex])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.repair(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "retry-awaiting-user-action"
        ))

        let terminal = try await coordinator.waitForOperation(
            operationID: accepted.operationID
        )

        XCTAssertEqual(terminal.phase, .completed)
        let final = await coordinator.snapshot()
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
        XCTAssertEqual(final.selectionRevision, initial.selectionRevision)
        XCTAssertEqual(final.providers.first {
            $0.descriptor.id == .codexDesktop
        }?.setupState, .configured)
    }

    func testSuccessfulRepairOfSelectedProviderAdvancesSelectionRevision() async throws {
        let lmStudio = FixtureProviderAdapter(
            providerID: .lmStudio,
            behavior: .awaitingInspectionThenRepaired
        )
        let coordinator = try makeCoordinator(adapters: [lmStudio])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.repair(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .lmStudio,
            idempotencyKey: "repair-selected-provider"
        ))

        let terminal = try await coordinator.waitForOperation(
            operationID: accepted.operationID
        )
        let final = await coordinator.snapshot()

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
        XCTAssertNotEqual(final.selectionRevision, initial.selectionRevision)
        XCTAssertEqual(terminal.resultingRevision, final.selectionRevision)

        do {
            _ = try await coordinator.select(.init(
                expectedRevision: initial.selectionRevision,
                providerID: nil,
                idempotencyKey: "stale-after-selected-repair"
            ))
            XCTFail("The pre-repair selection revision must be fenced as stale.")
        } catch let error as ProviderIntegrationError {
            XCTAssertEqual(
                error,
                .revisionConflict(
                    expected: initial.selectionRevision,
                    actual: final.selectionRevision
                )
            )
        }
    }

    func testCancellationIsDurableAndDoesNotChangeSelection() async throws {
        let claude = FixtureProviderAdapter(
            providerID: .claudeDesktop,
            behavior: .slow
        )
        let coordinator = try makeCoordinator(adapters: [claude])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "cancel-selection"
        ))
        try await waitForPhase(
            .staging,
            operationID: accepted.operationID,
            coordinator: coordinator
        )
        let cancelled = try await coordinator.cancel(operationID: accepted.operationID)

        XCTAssertEqual(cancelled.phase, .cancelled)
        let final = await coordinator.snapshot()
        let cancellationCount = await claude.cancellationCount
        XCTAssertEqual(final.selectedProviderID, .lmStudio)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCancellationDoesNotBecomeTerminalUntilHostMutationDrains() async throws {
        let claude = FixtureProviderAdapter(
            providerID: .claudeDesktop,
            behavior: .uncooperative
        )
        let coordinator = try makeCoordinator(adapters: [claude])
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "drain-before-cancelled"
        ))
        try await waitForPhase(
            .staging,
            operationID: accepted.operationID,
            coordinator: coordinator
        )

        let cancellation = Task {
            try await coordinator.cancel(operationID: accepted.operationID)
        }
        for _ in 0..<200 {
            if await claude.cancellationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let cancellationCount = await claude.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        let draining = try await coordinator.operation(operationID: accepted.operationID)
        let drainingSnapshot = await coordinator.snapshot()
        XCTAssertFalse(draining.isTerminal)
        XCTAssertEqual(drainingSnapshot.selectedProviderID, .lmStudio)

        await claude.releaseProvision()
        let cancelled = try await cancellation.value
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertTrue(cancelled.detail?.contains("drained") == true)
        XCTAssertEqual(finalSnapshot.selectedProviderID, .lmStudio)
    }

    func testRestartRecoversNonterminalOperationWithoutChangingSelection() async throws {
        let claude = FixtureProviderAdapter(
            providerID: .claudeDesktop,
            behavior: .blockedInspection
        )
        let original = try makeCoordinator(adapters: [claude])
        let initial = await original.snapshot()
        let accepted = try await original.select(.init(
            expectedRevision: initial.selectionRevision,
            providerID: .claudeDesktop,
            idempotencyKey: "restart-recovery"
        ))
        try await waitForPhase(
            .inspectingHost,
            operationID: accepted.operationID,
            coordinator: original
        )

        let restarted = try makeCoordinator(adapters: [claude])
        let recovered = try await restarted.operation(operationID: accepted.operationID)
        let snapshot = await restarted.snapshot()
        XCTAssertEqual(recovered.phase, .failedRecoverable)
        XCTAssertEqual(recovered.errorCode, "interrupted_by_restart")
        XCTAssertEqual(snapshot.selectedProviderID, .lmStudio)
        XCTAssertEqual(snapshot.selectionRevision, initial.selectionRevision)

        await claude.releaseInspection()
        _ = try await original.waitForOperation(operationID: accepted.operationID)
    }

    func testRecentHistoryIsBoundedToThirtyTwoOperations() async throws {
        let coordinator = try makeCoordinator(adapters: [])
        for index in 0..<40 {
            let snapshot = await coordinator.snapshot()
            let accepted = try await coordinator.select(.init(
                expectedRevision: snapshot.selectionRevision,
                providerID: nil,
                idempotencyKey: "history-\(index)"
            ))
            _ = try await coordinator.waitForOperation(operationID: accepted.operationID)
        }

        let final = await coordinator.snapshot()
        XCTAssertEqual(final.recentOperations.count, 32)
        XCTAssertEqual(final.recentOperations.first?.idempotencyKeySHA256, JSONSupport.sha256Hex("history-39"))
        XCTAssertEqual(final.recentOperations.last?.idempotencyKeySHA256, JSONSupport.sha256Hex("history-8"))
    }

    func testGrokBuildIsDiscoverableButCannotActivateWithoutSupportedIngress() async throws {
        let grok = FixtureProviderAdapter(providerID: .grokBuild)
        let coordinator = try makeCoordinator(adapters: [grok])
        let snapshot = await coordinator.snapshot()
        let discovered = try XCTUnwrap(snapshot.providers.first {
            $0.descriptor.id == .grokBuild
        })
        XCTAssertFalse(discovered.descriptor.selectable)
        XCTAssertTrue(discovered.descriptor.detail.contains("cannot deliver assignment context"))

        do {
            _ = try await coordinator.select(.init(
                expectedRevision: snapshot.selectionRevision,
                providerID: .grokBuild,
                idempotencyKey: "grok-unsupported-ingress"
            ))
            XCTFail("Grok activation unexpectedly succeeded")
        } catch {
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerNotSelectable(providerID: .grokBuild)
            )
        }
        let unchanged = await coordinator.snapshot()
        XCTAssertEqual(unchanged.selectedProviderID, snapshot.selectedProviderID)
        XCTAssertEqual(unchanged.selectionRevision, snapshot.selectionRevision)
        XCTAssertNil(unchanged.currentOperation)
    }

    func testDeactivationRetainsReceiptAndSelectiveRemoveClearsIt() async throws {
        let codex = FixtureProviderAdapter(providerID: .codexDesktop)
        let coordinator = try makeCoordinator(adapters: [codex])
        var snapshot = await coordinator.snapshot()
        var accepted = try await coordinator.select(.init(
            expectedRevision: snapshot.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "install-codex"
        ))
        _ = try await coordinator.waitForOperation(operationID: accepted.operationID)

        snapshot = await coordinator.snapshot()
        accepted = try await coordinator.select(.init(
            expectedRevision: snapshot.selectionRevision,
            providerID: nil,
            idempotencyKey: "deactivate-codex"
        ))
        _ = try await coordinator.waitForOperation(operationID: accepted.operationID)
        snapshot = await coordinator.snapshot()
        XCTAssertNil(snapshot.selectedProviderID)
        XCTAssertEqual(snapshot.providers.first {
            $0.descriptor.id == .codexDesktop
        }?.setupState, .configured)

        let removed = try await coordinator.remove(.init(
            expectedRevision: snapshot.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "remove-codex"
        ))
        let removedTerminal = try await coordinator.waitForOperation(
            operationID: removed.operationID
        )
        XCTAssertEqual(removedTerminal.phase, .removed)
        let removedSnapshot = await coordinator.snapshot()
        XCTAssertEqual(removedSnapshot.providers.first {
            $0.descriptor.id == .codexDesktop
        }?.setupState, .notConfigured)
        let removalCount = await codex.removalCount
        XCTAssertEqual(removalCount, 1)
    }

    func testLMStudioAdapterMapsVerifiedDeploymentToRedactedReceipt() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = LMStudioProviderIntegrationAdapter(
            status: {
                LMStudioMCPPluginInstaller.PluginStatus(
                    primaryPluginInstalled: true,
                    fallbackPluginInstalled: true,
                    mcpJSONRegistered: true,
                    binaryPath: "/private/redacted/forge-conductor",
                    binaryExecutable: true,
                    lmStudioPresent: true,
                    primaryPluginPath: "/private/redacted/primary",
                    fallbackPluginPath: "/private/redacted/fallback",
                    mcpConfigPath: "/private/redacted/mcp.json",
                    deploymentID: "deployment-v1",
                    detail: "verified",
                    continuityPluginInstalled: true
                )
            },
            deploy: { throw FixtureProviderFailure.rejected },
            remove: {},
            now: { timestamp }
        )

        let inspection = try await adapter.inspect(operationID: "inspect-lm")
        XCTAssertEqual(inspection.state, .ready)
        let receipt = try XCTUnwrap(inspection.receipt)
        XCTAssertEqual(receipt.providerID, .lmStudio)
        XCTAssertEqual(receipt.artifactVersion, "deployment-v1")
        XCTAssertEqual(receipt.metadata["mcp_roles"], "primary,fallback,continuity")
        XCTAssertFalse(receipt.metadata.values.contains { $0.contains("/private/") })
    }

    func testLMStudioAdapterDoesNotReportDegradedDeploymentReady() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = LMStudioProviderIntegrationAdapter(
            status: {
                LMStudioMCPPluginInstaller.PluginStatus(
                    primaryPluginInstalled: false,
                    fallbackPluginInstalled: false,
                    mcpJSONRegistered: false,
                    binaryPath: "",
                    binaryExecutable: false,
                    lmStudioPresent: true,
                    primaryPluginPath: "",
                    fallbackPluginPath: "",
                    mcpConfigPath: "",
                    deploymentID: nil,
                    detail: "missing",
                    continuityPluginInstalled: false
                )
            },
            deploy: {
                LMStudioMCPPluginInstaller.InstallResult(
                    ok: false,
                    binaryPath: "/private/redacted/forge-conductor",
                    pluginsWritten: ["primary", "fallback", "continuity"],
                    mcpConfigPath: "/private/redacted/mcp.json",
                    deploymentID: "deployment-degraded",
                    message: "host activation pending"
                )
            },
            remove: {},
            now: { timestamp }
        )

        let inspection = try await adapter.inspect(operationID: "inspect-missing-lm")
        XCTAssertEqual(inspection.state, .requiresProvisioning)
        let result = try await adapter.provision(.init(
            operationID: "provision-lm",
            kind: .activate,
            existingReceipt: nil
        ))
        XCTAssertEqual(result.state, .awaitingUserAction)
        XCTAssertEqual(result.receipt?.artifactVersion, "deployment-degraded")
    }

    func testDesktopRunAdmissionRequiresLiveMatchingDeploymentAndNoOperation() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let projectRoot = directory.appendingPathComponent("desktop-admission", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)

        let codex = FixtureProviderAdapter(providerID: .codexDesktop)
        let coordinator = try makeCoordinator(adapters: [codex])
        let initial = await coordinator.snapshot()
        let selectionRequest = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "desktop-admission-select"
        )
        let accepted = try await coordinator.select(selectionRequest)
        let selected = try await coordinator.waitForOperation(operationID: accepted.operationID)
        XCTAssertEqual(selected.phase, .active)
        await codex.setBehavior(.ready)

        let manager = ManagerNode(
            app: app,
            providerIntegrationCoordinator: coordinator
        )
        let operatorSnapshot = try manager.operatorSnapshot(limit: 10)
        XCTAssertEqual(operatorSnapshot.runPreparation.state, "ready")
        XCTAssertEqual(
            operatorSnapshot.runPreparation.providerID,
            ProviderIntegrationID.codexDesktop.rawValue
        )
        XCTAssertEqual(
            operatorSnapshot.runPreparation.adapterID,
            "forge.desktop-plugin.codex-desktop"
        )
        XCTAssertEqual(operatorSnapshot.runPreparation.modelKey, "host-selected")
        XCTAssertEqual(
            operatorSnapshot.runPreparation.providerConfigurationRevision,
            selected.resultingRevision
        )
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))

        let ready = try manager.prepareAutonomousRun(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Exercise a live desktop integration."
        )
        XCTAssertEqual(ready.providerID, ProviderIntegrationID.codexDesktop.rawValue)
        XCTAssertEqual(ready.modelKey, "host-selected")

        let invalidDesktop = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Preserve the selected desktop provider error.",
            adapterID: "wrong-desktop-adapter"
        )
        XCTAssertEqual(invalidDesktop.readiness, .needsChoice)
        XCTAssertEqual(invalidDesktop.recoveryAction, .retryPreparation)
        XCTAssertTrue(invalidDesktop.detail.contains("desktop provider integration"))
        XCTAssertFalse(invalidDesktop.detail.localizedCaseInsensitiveContains("local model"))

        let inspectionBaseline = await codex.inspectionStats()
        await codex.setBehavior(.blockedInspection)
        let blockedPreparation = Task.detached {
            manager.inspectAutonomousRunPreparation(
                projectID: projectID,
                expectedGeneration: generation,
                mission: "Hold one live desktop inspection."
            )
        }
        let inspectionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < inspectionDeadline {
            let stats = await codex.inspectionStats()
            if stats.calls > inspectionBaseline.calls { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let enteredStats = await codex.inspectionStats()
        guard enteredStats.calls > inspectionBaseline.calls else {
            await codex.releaseInspection()
            _ = await blockedPreparation.value
            return XCTFail("The first desktop inspection did not enter its live adapter")
        }
        let beforeOverlap = ContinuousClock.now
        let overlapping = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Reject an overlapping live desktop inspection."
        )
        let overlapElapsed = beforeOverlap.duration(to: ContinuousClock.now)
        XCTAssertEqual(overlapping.readiness, .failed)
        XCTAssertTrue(overlapping.detail.localizedCaseInsensitiveContains("operation"))
        XCTAssertLessThan(overlapElapsed, .seconds(1))
        let duringOverlapStats = await codex.inspectionStats()
        XCTAssertEqual(duringOverlapStats.maximumActive, 1)
        await codex.releaseInspection()
        _ = await blockedPreparation.value
        await codex.setBehavior(.ready)
        let afterDrain = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Retry after the prior live inspection drained."
        )
        XCTAssertEqual(afterDrain.readiness, .ready)

        await codex.setBehavior(.readyDrifted)
        XCTAssertThrowsError(try manager.prepareAutonomousRun(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Reject a drifted desktop integration."
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer matches"))
        }

        await codex.setBehavior(.slow)
        let beforeRepair = await coordinator.snapshot()
        let repair = try await coordinator.repair(ProviderIntegrationMutationRequest(
            expectedRevision: beforeRepair.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "desktop-admission-repair"
        ))
        XCTAssertThrowsError(try manager.prepareAutonomousRun(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Reject admission while repair is active."
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("integration operation"))
        }
        _ = try await coordinator.cancel(operationID: repair.operationID)
    }

    func testProviderSelectionRejectsNonterminalDesktopRunsAndPreservesReplay() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let projectRoot = directory.appendingPathComponent("desktop-selection", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)

        let codex = FixtureProviderAdapter(providerID: .codexDesktop)
        let claude = FixtureProviderAdapter(providerID: .claudeDesktop)
        let grok = FixtureProviderAdapter(providerID: .grokBuild)
        let coordinator = try makeCoordinator(adapters: [codex, claude, grok])
        let initial = await coordinator.snapshot()
        let selectionRequest = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "desktop-active-run-select"
        )
        let accepted = try await coordinator.select(selectionRequest)
        _ = try await coordinator.waitForOperation(operationID: accepted.operationID)
        await codex.setBehavior(.ready)

        let manager = ManagerNode(
            app: app,
            providerIntegrationCoordinator: coordinator
        )
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        let canonicalRoot = try XCTUnwrap(
            try app.projectContexts.project(projectID)?.canonicalRoot
        )
        let beforeRepair = await coordinator.snapshot()
        let repairRequest = try ProviderIntegrationMutationRequest(
            expectedRevision: beforeRepair.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "desktop-active-run-repair"
        )
        let repairAccepted = try manager.repairProviderIntegration(repairRequest)
        let repairCompleted = try await coordinator.waitForOperation(
            operationID: repairAccepted.operationID
        )
        XCTAssertEqual(repairCompleted.phase, .completed)
        let selectedSnapshot = await coordinator.snapshot()
        let historicalRemoveRequest = try ProviderIntegrationMutationRequest(
            expectedRevision: selectedSnapshot.selectionRevision,
            providerID: .grokBuild,
            idempotencyKey: "historical-grok-remove"
        )
        let historicalRemove = try manager.removeProviderIntegration(
            historicalRemoveRequest
        )
        let historicalRemoveCompleted = try await coordinator.waitForOperation(
            operationID: historicalRemove.operationID
        )
        XCTAssertEqual(historicalRemoveCompleted.phase, .removed)
        _ = try await app.projectContexts.repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: generation,
                mission: "Keep the selected desktop provider bound while work remains active.",
                providerID: ProviderIntegrationID.codexDesktop.rawValue,
                adapterID: "forge.desktop-plugin.codex-desktop",
                modelKey: "host-selected",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fs_read"],
                    completionGates: ["fixture"],
                    work: AutonomousRunWork(metadata: [
                        "execution_strategy": ProviderExecutionStrategy.desktopPluginPull.rawValue,
                        "provider_selection_revision": selectedSnapshot.selectionRevision,
                    ])
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [canonicalRoot],
                    allowedTools: ["fs_read"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
        )
        _ = try await app.projectContexts.repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: generation,
                mission: "Preserve an inactive legacy desktop provider run.",
                providerID: ProviderIntegrationID.grokBuild.rawValue,
                adapterID: "forge.desktop-plugin.grok-build",
                modelKey: "host-selected",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fs_read"],
                    completionGates: ["fixture"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [canonicalRoot],
                    allowedTools: ["fs_read"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
        )

        XCTAssertThrowsError(try manager.selectProviderIntegration(
            ProviderSelectionRequest(
                expectedRevision: selectedSnapshot.selectionRevision,
                providerID: .claudeDesktop,
                idempotencyKey: "blocked-desktop-switch"
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerHasNonterminalRuns(providerID: .codexDesktop)
            )
        }

        XCTAssertThrowsError(try manager.repairProviderIntegration(
            ProviderIntegrationMutationRequest(
                expectedRevision: selectedSnapshot.selectionRevision,
                providerID: .codexDesktop,
                idempotencyKey: "blocked-selected-desktop-repair"
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerHasNonterminalRuns(providerID: .codexDesktop)
            )
        }
        XCTAssertThrowsError(try manager.removeProviderIntegration(
            ProviderIntegrationMutationRequest(
                expectedRevision: selectedSnapshot.selectionRevision,
                providerID: .grokBuild,
                idempotencyKey: "blocked-grok-remove"
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerHasNonterminalRuns(providerID: .grokBuild)
            )
        }
        let unchanged = await coordinator.snapshot()
        XCTAssertEqual(unchanged.selectedProviderID, .codexDesktop)
        XCTAssertNil(unchanged.currentOperation)

        XCTAssertThrowsError(try manager.selectProviderIntegration(
            ProviderSelectionRequest(
                expectedRevision: unchanged.selectionRevision,
                providerID: .codexDesktop,
                idempotencyKey: "blocked-desktop-reselection"
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerHasNonterminalRuns(providerID: .codexDesktop)
            )
        }

        let replay = try manager.selectProviderIntegration(selectionRequest)
        XCTAssertEqual(replay.operationID, accepted.operationID)
        let repairReplay = try manager.repairProviderIntegration(repairRequest)
        XCTAssertEqual(repairReplay.operationID, repairAccepted.operationID)
        let removeReplay = try manager.removeProviderIntegration(historicalRemoveRequest)
        XCTAssertEqual(removeReplay.operationID, historicalRemove.operationID)
    }

    func testInactiveDesktopTargetRejectsSelectionRepairAndRemovalForLegacyRun() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let projectRoot = directory.appendingPathComponent(
            "inactive-desktop-run",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let grok = FixtureProviderAdapter(providerID: .grokBuild)
        let coordinator = try makeCoordinator(adapters: [grok])
        let initial = await coordinator.snapshot()
        let manager = ManagerNode(app: app, providerIntegrationCoordinator: coordinator)
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        let canonicalRoot = try XCTUnwrap(
            try app.projectContexts.project(projectID)?.canonicalRoot
        )
        _ = try await app.projectContexts.repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: generation,
                mission: "Preserve a legacy run whose provider ledger is inactive.",
                providerID: ProviderIntegrationID.grokBuild.rawValue,
                adapterID: "forge.desktop-plugin.grok-build",
                modelKey: "host-selected",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fs_read"],
                    completionGates: ["fixture"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [canonicalRoot],
                    allowedTools: ["fs_read"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            )
        )

        XCTAssertThrowsError(try manager.selectProviderIntegration(
            ProviderSelectionRequest(
                expectedRevision: initial.selectionRevision,
                providerID: .grokBuild,
                idempotencyKey: "inactive-target-select"
            )
        )) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerHasNonterminalRuns(providerID: .grokBuild)
            )
        }
        for (kind, operation) in [
            ("repair", { try manager.repairProviderIntegration(
                ProviderIntegrationMutationRequest(
                    expectedRevision: initial.selectionRevision,
                    providerID: .grokBuild,
                    idempotencyKey: "inactive-target-repair"
                )
            ) }),
            ("remove", { try manager.removeProviderIntegration(
                ProviderIntegrationMutationRequest(
                    expectedRevision: initial.selectionRevision,
                    providerID: .grokBuild,
                    idempotencyKey: "inactive-target-remove"
                )
            ) }),
        ] {
            XCTAssertThrowsError(try operation(), "\(kind) must preserve the legacy run") { error in
                XCTAssertEqual(
                    error as? ProviderIntegrationError,
                    .providerHasNonterminalRuns(providerID: .grokBuild)
                )
            }
        }
        let unchanged = await coordinator.snapshot()
        XCTAssertEqual(unchanged.selectedProviderID, initial.selectedProviderID)
        XCTAssertEqual(unchanged.selectionRevision, initial.selectionRevision)
        XCTAssertNil(unchanged.currentOperation)
    }

    func testManagerLMStudioSelectionRequiresCurrentExactReadinessReceipt() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let lmStudio = FixtureProviderAdapter(providerID: .lmStudio, behavior: .ready)
        let coordinator = try ProviderIntegrationCoordinator(
            paths: app.paths,
            adapters: [lmStudio],
            defaultSelectedProviderID: .codexDesktop
        )
        let configuration = ProviderConfigurationSnapshot(
            revision: "lm-selection-ready-v1",
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model",
            credentialConfigured: false,
            saved: true
        )
        let configurationService = FixtureProviderConfigurationService(snapshot: configuration)
        let registry = HostAdapterRegistry()
        registry.register(
            manifest: HostPluginManifest(
                identifier: ManagerNode.nativeSessionHostAdapterID,
                version: "fixture",
                minimumContractVersion: 2,
                hostType: "fixture",
                capabilities: HostCapabilities(
                    create: true,
                    bootstrap: true,
                    usageReporting: true,
                    resume: true,
                    idempotency: true,
                    queryByIdempotencyKey: true
                ),
                configurationKeys: [],
                privacyRequirements: [],
                migrationVersion: 1
            ),
            configurationFactory: { _ in configurationService },
            factory: { _ -> any SessionHostAdapter in
                throw FixtureProviderFailure.rejected
            }
        )
        let manager = ManagerNode(
            app: app,
            providerIntegrationCoordinator: coordinator,
            hostAdapterRegistry: registry
        )
        let initial = await coordinator.snapshot()
        let rejectedRequest = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .lmStudio,
            idempotencyKey: "lm-without-readiness"
        )

        XCTAssertThrowsError(try manager.selectProviderIntegration(rejectedRequest)) { error in
            XCTAssertEqual(
                error as? ProviderIntegrationError,
                .providerNotReady(providerID: .lmStudio)
            )
        }
        let rejectedSnapshot = await coordinator.snapshot()
        XCTAssertEqual(rejectedSnapshot.selectedProviderID, .codexDesktop)
        XCTAssertEqual(rejectedSnapshot.selectionRevision, initial.selectionRevision)
        XCTAssertNil(rejectedSnapshot.currentOperation)

        let checkedAt = ISO8601.string(from: app.clock.now())
        let receiptDirectory = app.paths.managedProvidersDir.appendingPathComponent(
            ManagerNode.nativeSessionHostAdapterID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: receiptDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try OwnerOnlyAtomicFile.write(
            try JSONSupport.data(from: [
                "schemaVersion": 1,
                "configurationRevision": configuration.revision,
                "checkedAt": checkedAt,
                "provider": [
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "provider_id": ProviderIntegrationID.lmStudio.rawValue,
                    "health": "contract_valid",
                    "endpoint": configuration.endpoint,
                    "credential_configured": false,
                    "api_mode": "managed_provider",
                    "model_key": "fixture/tool-model",
                    "tool_use_capable": true,
                    "contract_fingerprint": String(repeating: "a", count: 64),
                    "last_probe_mode": ManagerProviderProbeMode.contract.rawValue,
                    "last_probe_at": checkedAt,
                ],
            ]),
            to: receiptDirectory.appendingPathComponent("provider-readiness.json")
        )

        let readyRequest = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .lmStudio,
            idempotencyKey: "lm-with-current-readiness"
        )
        let accepted = try manager.selectProviderIntegration(readyRequest)
        let terminal = try await coordinator.waitForOperation(operationID: accepted.operationID)
        XCTAssertEqual(terminal.phase, .active)
        let selected = await coordinator.snapshot()
        XCTAssertEqual(selected.selectedProviderID, .lmStudio)
        XCTAssertNotEqual(selected.selectionRevision, initial.selectionRevision)
    }

    func testInstructionQueueAdmissionFencesProviderSwitchUntilDesktopRunIsDurable() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer {
            Self.makeInstructionSnapshotsRemovable(app.paths.instructionPackageStoreDir)
            app.shutdown()
        }
        let projectRoot = directory.appendingPathComponent("desktop-queue-race", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)

        let codex = FixtureProviderAdapter(providerID: .codexDesktop)
        let claude = FixtureProviderAdapter(providerID: .claudeDesktop)
        let coordinator = try makeCoordinator(adapters: [codex, claude])
        let initial = await coordinator.snapshot()
        let selected = try await coordinator.select(ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "desktop-queue-select"
        ))
        _ = try await coordinator.waitForOperation(operationID: selected.operationID)
        await codex.setBehavior(.ready)
        let selectedSnapshot = await coordinator.snapshot()

        let providerAdmissionGate = ProviderAdmissionTestGate()
        let manager = ManagerNode(
            app: app,
            providerIntegrationCoordinator: coordinator,
            instructionRunAdmissionCheckpoint: { checkpoint in
                guard checkpoint == .providerResolved else { return }
                try providerAdmissionGate.enterAndWait()
            }
        )
        defer { _ = manager.shutdownManagedAutonomy() }
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        let instruction = directory.appendingPathComponent("desktop-queue.md")
        try Data("Complete the fenced desktop queue task.".utf8).write(
            to: instruction,
            options: .atomic
        )
        _ = try manager.importInstructionPackage(
            sourcePath: instruction.path,
            projectID: projectID,
            expectedGeneration: generation
        )
        _ = try manager.recoverManagedAutonomy()
        _ = try manager.startInstructionQueue(
            projectID: projectID,
            expectedGeneration: generation
        )

        let reachedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !providerAdmissionGate.isEntered(), ContinuousClock.now < reachedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reached = providerAdmissionGate.isEntered()
        XCTAssertTrue(reached, "Instruction admission did not reach the provider-resolved fence")
        let selectionStarted = ProviderAdmissionObservation()
        let attemptedSwitch = Task.detached {
            selectionStarted.record()
            return Result {
                try manager.selectProviderIntegration(ProviderSelectionRequest(
                    expectedRevision: selectedSnapshot.selectionRevision,
                    providerID: .claudeDesktop,
                    idempotencyKey: "desktop-queue-racing-switch"
                ))
            }
        }
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !selectionStarted.isObserved(), ContinuousClock.now < selectionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(selectionStarted.isObserved(), "Provider switch did not reach its admission attempt")
        providerAdmissionGate.open()
        let switchResult = await attemptedSwitch.value
        switch switchResult {
        case .success:
            XCTFail("Provider switch crossed the instruction-run admission fence")
        case .failure(let error):
            guard let providerError = error as? ProviderIntegrationError else {
                return XCTFail("Unexpected switch error: \(error)")
            }
            switch providerError {
            case .operationBusy(operationID: "provider-run-admission"),
                 .providerHasNonterminalRuns(providerID: .codexDesktop):
                break
            default:
                XCTFail("Unexpected provider admission result: \(providerError)")
            }
        }

        var durableRun: AutonomousRunRecord?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while durableRun == nil, ContinuousClock.now < deadline {
            let queue = try manager.instructionQueue(
                projectID: projectID,
                expectedGeneration: generation
            )
            if let package = (queue["packages"] as? [[String: Any]])?.first,
               let rawRunID = package["run_id"] as? String,
               let runUUID = UUID(uuidString: rawRunID) {
                durableRun = try await app.projectContexts.repository.autonomousRun(
                    RunID(runUUID)
                )
            }
            if durableRun == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let run = try XCTUnwrap(durableRun)
        XCTAssertEqual(
            run.specification.work.metadata["provider_selection_revision"],
            selectedSnapshot.selectionRevision
        )
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertEqual(finalSnapshot.selectedProviderID, .codexDesktop)
        XCTAssertEqual(finalSnapshot.selectionRevision, selectedSnapshot.selectionRevision)
    }

    private func makeCoordinator(
        adapters: [any ProviderIntegrationAdapting]
    ) throws -> ProviderIntegrationCoordinator {
        try ProviderIntegrationCoordinator(
            paths: AppPaths(home: directory),
            adapters: adapters
        )
    }

    private func waitForPhase(
        _ phase: ProviderIntegrationOperationPhase,
        operationID: String,
        coordinator: ProviderIntegrationCoordinator
    ) async throws {
        for _ in 0..<200 {
            if try await coordinator.operation(operationID: operationID).phase == phase {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Operation \(operationID) did not reach \(phase.rawValue).")
    }

    private static func makeInstructionSnapshotsRemovable(_ root: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        var entries: [URL] = []
        for case let entry as URL in enumerator { entries.append(entry) }
        for entry in entries.reversed() {
            let directory = (try? entry.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory == true
            try? FileManager.default.setAttributes(
                [.posixPermissions: directory ? 0o700 : 0o600],
                ofItemAtPath: entry.path
            )
        }
    }
}

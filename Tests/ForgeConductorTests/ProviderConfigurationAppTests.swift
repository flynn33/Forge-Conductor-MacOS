import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

private actor ProviderBusyService: ProviderConfigurationServicing {
    var entered = false
    var updates = 0
    private let snapshot = ProviderConfigurationSnapshot(revision: "0", endpoint: "http://127.0.0.1:1234",
        modelKey: nil, credentialConfigured: false, saved: true)
    func read() -> ProviderConfigurationSnapshot { snapshot }
    func update(_ request: ProviderConfigurationUpdate) -> ProviderConfigurationSnapshot {
        updates += 1
        return snapshot
    }
    func models() async throws -> ProviderModelInventory {
        entered = true
        try await Task.sleep(for: .seconds(1))
        return ProviderModelInventory(revision: "0", models: [])
    }
}

private actor LegacyLMProviderSelectionClient: OperatorManagerClientProtocol {
    private let operatorSnapshot: OperatorSnapshot
    private let integrationSnapshot: ProviderIntegrationsSnapshot
    private let preparationState: ManagerProviderPreparationState
    private let simulateLostSelectionResponse: Bool
    private let providerOperationFailuresBeforeSuccess: Int
    private let providerRegistryDelayNanoseconds: UInt64
    private let legacySnapshotDelayNanoseconds: UInt64
    private let configurationSaved: Bool
    private var acceptedSelectionOperation: ProviderIntegrationOperationSnapshot?
    private(set) var repairRequests: [ProviderIntegrationMutationRequest] = []
    private(set) var removeRequests: [ProviderIntegrationMutationRequest] = []
    private(set) var selectionRequests: [ProviderSelectionRequest] = []
    private(set) var callOrder: [String] = []
    private(set) var providerOperationPollCount = 0

    init(
        preparationState: ManagerProviderPreparationState = .ready,
        selectedProviderID: ProviderIntegrationID? = .lmStudio,
        receiptProviderID: ProviderIntegrationID? = nil,
        simulateLostSelectionResponse: Bool = false,
        providerOperationFailuresBeforeSuccess: Int = 0,
        providerRegistryDelayNanoseconds: UInt64 = 0,
        legacySnapshotDelayNanoseconds: UInt64 = 0,
        configurationSaved: Bool = false
    ) throws {
        self.preparationState = preparationState
        self.simulateLostSelectionResponse = simulateLostSelectionResponse
        self.providerOperationFailuresBeforeSuccess = providerOperationFailuresBeforeSuccess
        self.providerRegistryDelayNanoseconds = providerRegistryDelayNanoseconds
        self.legacySnapshotDelayNanoseconds = legacySnapshotDelayNanoseconds
        self.configurationSaved = configurationSaved
        operatorSnapshot = try JSONDecoder().decode(
            OperatorSnapshot.self,
            from: Data("{}".utf8)
        )
        let receipt = try receiptProviderID.map { providerID in
            try ProviderIntegrationReceipt(
                providerID: providerID,
                artifactVersion: "legacy-fixture-v1",
                installedAt: "2026-09-23T12:00:00Z",
                verifiedAt: "2026-09-23T12:00:00Z",
                metadata: ["fixture": "legacy"]
            )
        }
        integrationSnapshot = ProviderIntegrationsSnapshot(
            selectionRevision: "legacy-lm-revision",
            selectedProviderID: selectedProviderID,
            providers: ProviderIntegrationDescriptor.supported.map {
                ProviderIntegrationProviderSnapshot(
                    descriptor: $0,
                    receipt: $0.id == receiptProviderID ? receipt : nil
                )
            },
            currentOperation: nil,
            recentOperations: []
        )
    }

    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
        _ = limit
        _ = cursor
        if legacySnapshotDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: legacySnapshotDelayNanoseconds)
        }
        return operatorSnapshot
    }

    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        if providerRegistryDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: providerRegistryDelayNanoseconds)
        }
        return ProviderIntegrationsSnapshot(
            selectionRevision: integrationSnapshot.selectionRevision,
            selectedProviderID: integrationSnapshot.selectedProviderID,
            providers: integrationSnapshot.providers,
            currentOperation: acceptedSelectionOperation,
            recentOperations: []
        )
    }

    func updateProviderSelection(
        _ request: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        callOrder.append("selection")
        selectionRequests.append(request)
        let providerID = request.providerID ?? .lmStudio
        if simulateLostSelectionResponse {
            acceptedSelectionOperation = operation(
                kind: .activate,
                phase: .committing,
                providerID: providerID
            )
            throw OperatorManagerClientError.rejected(
                status: 504,
                message: "The response was lost after the manager accepted the operation."
            )
        }
        return operation(kind: .activate, phase: .active, providerID: providerID)
    }

    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        guard operationID == acceptedSelectionOperation?.operationID else {
            throw OperatorManagerClientError.invalidPayload("unexpected operation id")
        }
        providerOperationPollCount += 1
        if providerOperationPollCount <= providerOperationFailuresBeforeSuccess {
            throw OperatorManagerClientError.rejected(
                status: 503,
                message: "Temporary manager outage."
            )
        }
        let completed = operation(
            kind: .activate,
            phase: .active,
            providerID: acceptedSelectionOperation?.providerID ?? .lmStudio
        )
        acceptedSelectionOperation = completed
        return completed
    }

    func repairProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        callOrder.append("repair")
        repairRequests.append(request)
        return operation(
            kind: .repair,
            phase: .completed,
            providerID: request.providerID
        )
    }

    func removeProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        callOrder.append("remove")
        removeRequests.append(request)
        return operation(kind: .remove, phase: .removed, providerID: request.providerID)
    }

    func prepareProvider() async throws -> ManagerProviderPreparationResult {
        callOrder.append("connect_and_check")
        return preparationResult()
    }

    func prepareProviderWithoutResumingRuns() async throws -> ManagerProviderPreparationResult {
        callOrder.append("connect_without_resume")
        return preparationResult()
    }

    private func preparationResult() -> ManagerProviderPreparationResult {
        return ManagerProviderPreparationResult(
            state: preparationState,
            recoveryAction: preparationState == .ready ? .none : .startService,
            detail: preparationState == .ready
                ? "LM Studio and the selected tool-capable model are ready for managed tasks."
                : "LM Studio still needs attention.",
            configuration: ProviderConfigurationSnapshot(
                revision: "legacy-provider-configuration",
                endpoint: "http://127.0.0.1:1234",
                modelKey: nil,
                credentialConfigured: false,
                saved: false
            )
        )
    }

    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        ProviderConfigurationSnapshot(
            revision: "legacy-provider-configuration",
            endpoint: "http://127.0.0.1:1234",
            modelKey: configurationSaved ? "fixture/tool-model" : nil,
            credentialConfigured: false,
            saved: configurationSaved
        )
    }

    private func operation(
        kind: ProviderIntegrationOperationKind,
        phase: ProviderIntegrationOperationPhase,
        providerID: ProviderIntegrationID = .lmStudio
    ) -> ProviderIntegrationOperationSnapshot {
        ProviderIntegrationOperationSnapshot(
            operationID: "legacy-lm-operation",
            kind: kind,
            providerID: providerID,
            phase: phase,
            expectedRevision: integrationSnapshot.selectionRevision,
            resultingRevision: integrationSnapshot.selectionRevision,
            idempotencyKeySHA256: String(repeating: "a", count: 64),
            intentSHA256: String(repeating: "b", count: 64),
            detail: "LM Studio integration verified.",
            acceptedAt: "2026-09-23T12:00:00Z",
            updatedAt: "2026-09-23T12:00:00Z",
            completedAt: phase.isTerminal ? "2026-09-23T12:00:00Z" : nil
        )
    }

    private var notInScope: OperatorManagerClientError {
        .invalidPayload("not exercised by this test")
    }

    func autonomyStatus() async throws -> OperatorAutonomySummary { throw notInScope }
    func settings() async throws -> ManagerSettings { throw notInScope }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings { throw notInScope }
    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome { throw notInScope }
    func projectStatus(projectID: String) async throws -> OperatorProject { throw notInScope }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        throw notInScope
    }
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt { throw notInScope }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw notInScope }
    func runStatus(runID: String) async throws -> OperatorRun { throw notInScope }
    func controlRun(
        runID: String,
        action: OperatorRunControlAction
    ) async throws -> OperatorRun { throw notInScope }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { throw notInScope }
    func updateProviderConfiguration(
        _ update: ProviderConfigurationUpdate
    ) async throws -> ProviderConfigurationSnapshot { throw notInScope }
    func providerModels() async throws -> ProviderModelInventory {
        guard configurationSaved else { throw notInScope }
        return ProviderModelInventory(
            revision: "legacy-provider-configuration",
            models: [ProviderAvailableModel(
                key: "fixture/tool-model",
                loaded: true,
                toolUseCapable: true
            )]
        )
    }
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider { throw notInScope }
}

final class ProviderConfigurationAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-client-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func request(_ revision: String = "0") -> ProviderConfigurationUpdate {
        ProviderConfigurationUpdate(expectedRevision: revision, endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model", credentialAction: .keep)
    }

    func testClientRouterPreservesPreparationWithoutRunResumption() async throws {
        let client = try LegacyLMProviderSelectionClient()
        let router = OperatorManagerClientRouter(client: client)

        _ = try await router.prepareProviderWithoutResumingRuns()

        let callOrder = await client.callOrder
        XCTAssertEqual(callOrder, ["connect_without_resume"])
    }

    @MainActor
    func testModelRefreshRunsWhileProviderRegistryRefreshIsStillInFlight() async throws {
        let client = try LegacyLMProviderSelectionClient(
            providerRegistryDelayNanoseconds: 500_000_000,
            configurationSaved: true
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<200 {
            if viewModel.configuration?.saved == true,
               viewModel.isLoadingProviderRegistry {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(viewModel.isLoadingProviderRegistry)
        XCTAssertTrue(viewModel.configuration?.saved == true)
        viewModel.refreshModels()
        for _ in 0..<200 {
            if !viewModel.availableModels.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(
            viewModel.availableModels,
            [ProviderAvailableModel(
                key: "fixture/tool-model",
                loaded: true,
                toolUseCapable: true
            )]
        )
    }

    @MainActor
    func testLegacyDefaultLMStudioOnActionRunsRepairInsteadOfNoOp() async throws {
        let client = try LegacyLMProviderSelectionClient()
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.selectedProviderID, .lmStudio)
        XCTAssertNil(viewModel.integration(for: .lmStudio)?.receipt)

        viewModel.setProvider(.lmStudio, enabled: true)
        for _ in 0..<500 {
            if await client.repairRequests.count == 1,
               !viewModel.isProbing,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let repairRequests = await client.repairRequests
        let selectionRequests = await client.selectionRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(repairRequests.count, 1)
        XCTAssertEqual(repairRequests.first?.providerID, .lmStudio)
        XCTAssertEqual(repairRequests.first?.expectedRevision, "legacy-lm-revision")
        XCTAssertEqual(selectionRequests, [])
        XCTAssertEqual(
            callOrder,
            ["connect_without_resume", "repair", "connect_and_check"]
        )
        XCTAssertTrue(
            viewModel.noticeMessage?.contains("ready for managed tasks") == true,
            "the completed setup message must preserve the provider-ready result after integration activation"
        )
    }

    @MainActor
    func testLMStudioPrimaryActionDoesNotDeployIntegrationBeforeReadiness() async throws {
        let client = try LegacyLMProviderSelectionClient(preparationState: .actionRequired)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.performProviderPrimaryAction(.lmStudio)
        for _ in 0..<500 {
            if !viewModel.isProbing { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let repairRequests = await client.repairRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(repairRequests, [])
        XCTAssertEqual(callOrder, ["connect_without_resume"])
        XCTAssertEqual(viewModel.preparation?.state, .actionRequired)
    }

    @MainActor
    func testInactiveLMStudioToggleConnectsBeforeSelecting() async throws {
        let client = try LegacyLMProviderSelectionClient(selectedProviderID: .codexDesktop)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProvider(.lmStudio, enabled: true)
        for _ in 0..<500 {
            if await client.selectionRequests.count == 1,
               !viewModel.isProbing,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequests = await client.selectionRequests
        let repairRequests = await client.repairRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(selectionRequests.count, 1)
        XCTAssertEqual(selectionRequests.first?.providerID, .lmStudio)
        XCTAssertEqual(repairRequests, [])
        XCTAssertEqual(
            callOrder,
            ["connect_without_resume", "selection", "connect_and_check"]
        )
    }

    @MainActor
    func testInactiveLMStudioToggleDoesNotSelectWhenReadinessNeedsAction() async throws {
        let client = try LegacyLMProviderSelectionClient(
            preparationState: .actionRequired,
            selectedProviderID: .codexDesktop
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProvider(.lmStudio, enabled: true)
        for _ in 0..<500 {
            if !viewModel.isProbing { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequests = await client.selectionRequests
        let repairRequests = await client.repairRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(selectionRequests, [])
        XCTAssertEqual(repairRequests, [])
        XCTAssertEqual(callOrder, ["connect_without_resume"])
        XCTAssertEqual(viewModel.preparation?.state, .actionRequired)
    }

    @MainActor
    func testActiveProviderCannotBeDeselectedWithoutChoosingReplacement() async throws {
        let client = try LegacyLMProviderSelectionClient(selectedProviderID: .codexDesktop)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProvider(.codexDesktop, enabled: false)
        try await Task.sleep(for: .milliseconds(20))

        let selectionRequests = await client.selectionRequests
        XCTAssertEqual(selectionRequests, [])
        XCTAssertEqual(viewModel.selectedProviderID, .codexDesktop)
        XCTAssertEqual(
            viewModel.noticeMessage,
            "Choose another provider to switch execution. Forge keeps one provider active."
        )
    }

    @MainActor
    func testLMStudioActivationSupersedesReplaceableBackgroundLoad() async throws {
        let client = try LegacyLMProviderSelectionClient(
            selectedProviderID: .codexDesktop,
            legacySnapshotDelayNanoseconds: 5_000_000_000
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if viewModel.integrations != nil, viewModel.isLoading { break }
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(viewModel.isLoading)
        viewModel.setProvider(.lmStudio, enabled: true)
        for _ in 0..<500 {
            if await client.selectionRequests.count == 1,
               !viewModel.isProbing,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequests = await client.selectionRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(selectionRequests.map(\.providerID), [.lmStudio])
        XCTAssertEqual(
            callOrder,
            ["connect_without_resume", "selection", "connect_and_check"]
        )
    }

    @MainActor
    func testAlreadySelectedDesktopProviderToggleDoesNotInvokeLMStudioConnectFlow() async throws {
        let client = try LegacyLMProviderSelectionClient(selectedProviderID: .codexDesktop)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProvider(.codexDesktop, enabled: true)
        try await Task.sleep(for: .milliseconds(20))

        let callOrder = await client.callOrder
        let repairRequests = await client.repairRequests
        let selectionRequests = await client.selectionRequests
        XCTAssertEqual(callOrder, [])
        XCTAssertEqual(repairRequests, [])
        XCTAssertEqual(selectionRequests, [])
    }

    @MainActor
    func testInactiveDesktopPrimaryActionUsesActivationWorkflow() async throws {
        let client = try LegacyLMProviderSelectionClient(selectedProviderID: .lmStudio)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.performProviderPrimaryAction(.codexDesktop)
        for _ in 0..<500 {
            if await client.selectionRequests.count == 1,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequests = await client.selectionRequests
        let repairRequests = await client.repairRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(selectionRequests.map(\.providerID), [.codexDesktop])
        XCTAssertEqual(selectionRequests.first?.expectedRevision, "legacy-lm-revision")
        XCTAssertEqual(repairRequests, [])
        XCTAssertEqual(callOrder, ["selection"])
    }

    @MainActor
    func testSelectedDesktopPrimaryActionInspectsAndRepairsIntegration() async throws {
        let client = try LegacyLMProviderSelectionClient(selectedProviderID: .claudeDesktop)
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.performProviderPrimaryAction(.claudeDesktop)
        for _ in 0..<500 {
            if await client.repairRequests.count == 1,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequests = await client.selectionRequests
        let repairRequests = await client.repairRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(repairRequests.map(\.providerID), [.claudeDesktop])
        XCTAssertEqual(repairRequests.first?.expectedRevision, "legacy-lm-revision")
        XCTAssertEqual(selectionRequests, [])
        XCTAssertEqual(callOrder, ["repair"])
    }

    func testProviderReceiptEvidenceShowsOperationalMetadataAndRedactsSensitiveKeys() {
        let details = ProviderReceiptEvidence.visibleDetails(
            from: [
                "cli_path": "/Users/fixture/Applications/codex",
                "cli_version": "2.7.1",
                "package_sha256": String(repeating: "a", count: 64),
                "deployment_verified": "true",
                "hook_trust_review_required": "false",
                "restart_required": "true",
                "connection": "verified",
                "credential_token": "must-not-render",
            ],
            homeDirectory: "/Users/fixture"
        )

        XCTAssertEqual(Set(details.map(\.key)), [
            "cli_path",
            "cli_version",
            "package_sha256",
            "deployment_verified",
            "hook_trust_review_required",
            "restart_required",
            "connection",
        ])
        XCTAssertEqual(details.first(where: { $0.key == "cli_path" })?.label, "CLI Path")
        XCTAssertEqual(
            details.first(where: { $0.key == "cli_path" })?.value,
            "~/Applications/codex"
        )
        XCTAssertEqual(
            details.first(where: { $0.key == "package_sha256" })?.label,
            "Package SHA-256"
        )
    }

    @MainActor
    func testLegacyNonselectableGrokReceiptOffersCleanupWithoutRepairOrToggle() async throws {
        let client = try LegacyLMProviderSelectionClient(
            selectedProviderID: nil,
            receiptProviderID: .grokBuild
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(viewModel.isProviderToggleDisabled(.grokBuild))
        XCTAssertFalse(viewModel.isProviderRepairAvailable(.grokBuild))
        XCTAssertFalse(viewModel.isProviderRemovalDisabled(.grokBuild))
        viewModel.performProviderPrimaryAction(.grokBuild)
        try await Task.sleep(for: .milliseconds(20))
        let ignoredRepairRequests = await client.repairRequests
        let ignoredSelectionRequests = await client.selectionRequests
        XCTAssertEqual(ignoredRepairRequests, [])
        XCTAssertEqual(ignoredSelectionRequests, [])
        viewModel.removeProviderIntegration(.grokBuild)
        for _ in 0..<500 {
            if await client.removeRequests.count == 1,
               !viewModel.isSubmittingProviderMutation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let removals = await client.removeRequests
        let callOrder = await client.callOrder
        XCTAssertEqual(removals.map(\.providerID), [.grokBuild])
        XCTAssertEqual(callOrder, ["remove"])
    }

    @MainActor
    func testGuidedHelpRecognizesVerifiedDesktopSelectionWithoutLMSetupGuidance() async throws {
        let client = try LegacyLMProviderSelectionClient(
            selectedProviderID: .codexDesktop,
            receiptProviderID: .codexDesktop
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.guidedHelpState.status, "Desktop provider is ready")
        XCTAssertNil(viewModel.guidedHelpState.recommendedAction)
        XCTAssertFalse(viewModel.guidedHelpState.detail.localizedCaseInsensitiveContains("LM Studio"))
    }

    @MainActor
    func testAcceptedProviderOperationIsObservedAfterMutationResponseIsLost() async throws {
        let client = try LegacyLMProviderSelectionClient(
            simulateLostSelectionResponse: true
        )
        let viewModel = ProviderViewModel(client: client)
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        viewModel.setProvider(.codexDesktop, enabled: true)
        for _ in 0..<500 {
            if await client.providerOperationPollCount == 1,
               viewModel.currentProviderOperation?.isTerminal == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let selectionRequestCount = await client.selectionRequests.count
        let operationPollCount = await client.providerOperationPollCount
        XCTAssertEqual(selectionRequestCount, 1)
        XCTAssertEqual(operationPollCount, 1)
        XCTAssertEqual(viewModel.currentProviderOperation?.phase, .active)
        XCTAssertFalse(viewModel.hasPendingProviderOperation)
    }

    @MainActor
    func testProviderOperationObservationRecoversAfterThreePollFailures() async throws {
        let client = try LegacyLMProviderSelectionClient(
            simulateLostSelectionResponse: true,
            providerOperationFailuresBeforeSuccess: 3
        )
        let viewModel = ProviderViewModel(
            client: client,
            providerOperationPollIntervalNanoseconds: 1_000_000
        )
        viewModel.load()
        for _ in 0..<500 {
            if !viewModel.isLoading && !viewModel.isLoadingProviderRegistry { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        viewModel.setProvider(.codexDesktop, enabled: true)
        for _ in 0..<1_000 {
            if await client.providerOperationPollCount == 4,
               viewModel.currentProviderOperation?.isTerminal == true {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }

        let operationPollCount = await client.providerOperationPollCount
        XCTAssertEqual(operationPollCount, 4)
        XCTAssertEqual(viewModel.currentProviderOperation?.phase, .active)
        XCTAssertFalse(viewModel.hasPendingProviderOperation)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRunPreparationResolverUsesDefaultsAndPreservesExplicitOverrides() throws {
        let configuration = ProviderConfigurationSnapshot(
            revision: "0",
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model",
            credentialConfigured: false,
            saved: true
        )
        let registered = ["fs_read", "fs_edit", "shell_exec"]
        let defaults = try ManagerRunPreparationResolver.resolve(
            configuration: configuration,
            registeredToolNames: registered
        )
        XCTAssertEqual(defaults.providerID, "lmstudio")
        XCTAssertEqual(defaults.adapterID, ManagerNode.nativeSessionHostAdapterID)
        XCTAssertEqual(defaults.modelKey, "fixture/tool-model")
        XCTAssertEqual(defaults.allowedTools, Set(registered))
        XCTAssertEqual(
            defaults.completionGates,
            [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        XCTAssertFalse(defaults.networkAllowed)

        let explicit = try ManagerRunPreparationResolver.resolve(
            configuration: configuration,
            registeredToolNames: registered,
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture/override",
            allowedTools: ["fs_read"],
            completionGates: ["fixture-gate"],
            networkAllowed: true
        )
        XCTAssertEqual(explicit.providerID, "fixture-provider")
        XCTAssertEqual(explicit.adapterID, "fixture-adapter")
        XCTAssertEqual(explicit.modelKey, "fixture/override")
        XCTAssertEqual(explicit.allowedTools, ["fs_read"])
        XCTAssertEqual(explicit.completionGates, ["fixture-gate"])
        XCTAssertTrue(explicit.networkAllowed)

        let explicitWithoutSettings = try ManagerRunPreparationResolver.resolve(
            configuration: nil,
            registeredToolNames: registered,
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture/override",
            allowedTools: ["fs_read"],
            completionGates: ["fixture-gate"],
            networkAllowed: true
        )
        XCTAssertEqual(explicitWithoutSettings, explicit)

        XCTAssertThrowsError(try ManagerRunPreparationResolver.resolve(
            configuration: configuration,
            registeredToolNames: registered,
            allowedTools: []
        ))
        XCTAssertThrowsError(try ManagerRunPreparationResolver.resolve(
            configuration: configuration,
            registeredToolNames: registered,
            completionGates: []
        ))
        XCTAssertThrowsError(try ManagerRunPreparationResolver.resolve(
            configuration: configuration,
            registeredToolNames: registered,
            modelKey: ""
        ))
    }

    func testHTTPStartUsesSavedManagerDefaultsWhenTechnicalFieldsAreOmitted() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        let port = Int.random(in: 29_000...39_000)
        let projectRoot = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update([
            "allowed_roots": [projectRoot.path],
            "dashboard": ["port": port],
        ], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = try? manager.stopService()
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let current = try manager.readProviderConfiguration()
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model"
        ))
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        _ = try manager.recoverManagedAutonomy()
        _ = try manager.startService()
        let preparation = try manager.operatorSnapshot(limit: 10).runPreparation

        let client = OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let startRequest = OperatorRunStartRequest(
            runID: UUID().uuidString.lowercased(),
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            assignmentID: nil,
            mission: "Use the manager-owned preparation defaults.",
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: nil,
            completionGates: nil,
            networkAllowed: nil,
            expectedProviderConfigurationRevision:
                preparation.providerConfigurationRevision,
            expectedToolCatalogRevision: preparation.toolCatalogRevision,
            maximumInlineOutputBytes: 64 * 1_024
        )
        let preparationResult = try await client.prepareRun(startRequest)
        XCTAssertEqual(preparationResult.readiness, .ready)
        XCTAssertEqual(preparationResult.recoveryAction, .none)
        let prepared = try XCTUnwrap(preparationResult.descriptor)
        XCTAssertEqual(prepared.projectID, projectID.description)
        XCTAssertEqual(prepared.projectGeneration, generation.rawValue)
        XCTAssertEqual(prepared.modelKey, "fixture/tool-model")
        let started = try await client.startRun(
            startRequest.expectingPreparedRevision(prepared.revision)
        )
        XCTAssertEqual(started.providerID, "lmstudio")
        XCTAssertEqual(started.modelKey, "fixture/tool-model")
        let runID = try RunID(XCTUnwrap(UUID(uuidString: started.runID)))
        let durable = try await app.projectContexts.repository.autonomousRun(runID)
        XCTAssertEqual(
            durable?.specification.allowedTools,
            ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.filter {
                Set(app.tools.toolNames).contains($0)
            }.sorted()
        )
        XCTAssertEqual(
            durable?.specification.completionGates,
            [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        XCTAssertEqual(
            durable?.specification.work.metadata["prepared_run_revision"],
            prepared.revision
        )
        XCTAssertEqual(
            durable?.specification.work.metadata["execution_strategy"],
            ProviderExecutionStrategy.managedProviderPush.rawValue
        )
        XCTAssertEqual(
            durable?.specification.work.metadata["provider_selection_revision"],
            try manager.providerIntegrations().selectionRevision
        )
    }

    func testHTTPStartRejectsStalePreparationBeforePersistingRun() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        let port = Int.random(in: 29_000...39_000)
        let projectRoot = directory.appendingPathComponent("stale-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update([
            "allowed_roots": [projectRoot.path],
            "dashboard": ["port": port],
        ], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = try? manager.stopService()
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let empty = try manager.readProviderConfiguration()
        let first = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: empty.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/first-model"
        ))
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        let stale = try manager.operatorSnapshot(limit: 10).runPreparation
        XCTAssertEqual(stale.providerConfigurationRevision, first.revision)
        let second = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: first.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/second-model"
        ))
        XCTAssertNotEqual(second.revision, first.revision)
        _ = try manager.recoverManagedAutonomy()
        _ = try manager.startService()
        let client = OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let runID = UUID().uuidString.lowercased()
        let staleRequest = OperatorRunStartRequest(
            runID: runID,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            assignmentID: nil,
            mission: "Reject stale manager preparation.",
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: nil,
            completionGates: nil,
            networkAllowed: nil,
            expectedProviderConfigurationRevision:
                stale.providerConfigurationRevision,
            expectedToolCatalogRevision: stale.toolCatalogRevision,
            maximumInlineOutputBytes: 64 * 1_024
        )
        do {
            _ = try await client.startRun(staleRequest)
            XCTFail("A stale prepared request was accepted")
        } catch let error as OperatorManagerClientError {
            guard case .configurationRejected(let code, _) = error else {
                return XCTFail("Wrong stale-preparation error: \(error)")
            }
            XCTAssertEqual(code, "run_preparation_stale")
        }
        let rejectedRunID = try RunID(XCTUnwrap(UUID(uuidString: runID)))
        let rejectedRun = try await app.projectContexts.repository.autonomousRun(rejectedRunID)
        XCTAssertNil(rejectedRun)

        let refreshed = try manager.operatorSnapshot(limit: 10).runPreparation
        let staleCatalogRequest = OperatorRunStartRequest(
            runID: runID,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            assignmentID: nil,
            mission: "Reject stale manager preparation.",
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: nil,
            completionGates: nil,
            networkAllowed: nil,
            expectedProviderConfigurationRevision:
                refreshed.providerConfigurationRevision,
            expectedToolCatalogRevision: String(repeating: "b", count: 64),
            maximumInlineOutputBytes: 64 * 1_024
        )
        do {
            _ = try await client.startRun(staleCatalogRequest)
            XCTFail("A stale tool-catalog preparation was accepted")
        } catch let error as OperatorManagerClientError {
            guard case .configurationRejected(let code, _) = error else {
                return XCTFail("Wrong stale-catalog error: \(error)")
            }
            XCTAssertEqual(code, "run_preparation_stale")
        }
        let catalogRejectedRun = try await app.projectContexts.repository.autonomousRun(
            rejectedRunID
        )
        XCTAssertNil(catalogRejectedRun)

        let accepted = try await client.startRun(OperatorRunStartRequest(
            runID: runID,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            assignmentID: nil,
            mission: "Reject stale manager preparation.",
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: nil,
            completionGates: nil,
            networkAllowed: nil,
            expectedProviderConfigurationRevision:
                refreshed.providerConfigurationRevision,
            expectedToolCatalogRevision: refreshed.toolCatalogRevision,
            maximumInlineOutputBytes: 64 * 1_024
        ))
        XCTAssertEqual(accepted.runID, runID)
        XCTAssertEqual(accepted.modelKey, "fixture/second-model")
    }

    func testPreparedRunDescriptorBindsSourceAuthorityValidationContinuityAndBudget() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        let projectRoot = directory.appendingPathComponent("prepared-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let current = try manager.readProviderConfiguration()
        let configured = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/prepared-model"
        ))
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        _ = try manager.recoverManagedAutonomy()

        let idleContinuity = try XCTUnwrap(
            manager.operatorSnapshot(limit: 10).continuityReadiness.first {
                $0.projectID == projectID && $0.runID == nil
            }
        )
        XCTAssertEqual(idleContinuity.state, .ready)
        XCTAssertTrue(idleContinuity.automatic)
        XCTAssertTrue(idleContinuity.detail.contains("no setup is required"))

        let mission = "Use the exact prepared source snapshot."
        let prepared = try manager.prepareAutonomousRun(
            projectID: projectID,
            expectedGeneration: generation,
            mission: mission
        )
        XCTAssertEqual(prepared.readiness, .ready)
        XCTAssertEqual(prepared.recoveryAction, .none)
        XCTAssertEqual(prepared.projectID, projectID.description)
        XCTAssertEqual(prepared.projectGeneration, generation.rawValue)
        XCTAssertEqual(prepared.source.kind, .inlineMission)
        XCTAssertEqual(prepared.source.snapshotSHA256, JSONSupport.sha256Hex(Data(mission.utf8)))
        XCTAssertEqual(prepared.providerConfigurationRevision, configured.revision)
        XCTAssertEqual(prepared.modelKey, "fixture/prepared-model")
        XCTAssertEqual(prepared.continuityMode, .managedAutonomous)
        XCTAssertEqual(prepared.validationPlan.completionGates, [ProjectInstructionQueueStore.builtInCompletionGate])
        XCTAssertEqual(prepared.validationPlan.mode, "automatic_completion_plan")
        let automaticPlan = try XCTUnwrap(prepared.validationPlan.automaticPlan)
        XCTAssertEqual(automaticPlan.projectID, projectID)
        XCTAssertEqual(automaticPlan.projectGeneration, generation)
        XCTAssertEqual(automaticPlan.instructionArtifactSHA256, [prepared.source.snapshotSHA256])
        XCTAssertEqual(
            Set(automaticPlan.obligations.map(\.kind)),
            [.artifactRegistered, .noRelevantUnresolvedSideEffect]
        )
        XCTAssertEqual(prepared.budgetPolicy.scope.projectID, projectID.description)
        XCTAssertEqual(prepared.budgetPolicy.scope.projectGeneration, Int(generation.rawValue))
        XCTAssertEqual(prepared.documents.count, 1)
        XCTAssertEqual(prepared.documents.first?.sha256, prepared.source.snapshotSHA256)

        let rejectedRunID = RunID()
        XCTAssertThrowsError(try manager.startAutonomousRun(
            runID: rejectedRunID,
            projectID: projectID,
            expectedGeneration: generation,
            mission: mission + " Changed",
            expectedPreparedRunRevision: prepared.revision
        )) { error in
            XCTAssertEqual(error as? ManagerRunPreparationError, .staleDescriptor)
        }
        let rejectedRun = try await app.projectContexts.repository.autonomousRun(rejectedRunID)
        XCTAssertNil(rejectedRun)

        let acceptedRunID = RunID()
        let accepted = try manager.startAutonomousRun(
            runID: acceptedRunID,
            projectID: projectID,
            expectedGeneration: generation,
            mission: mission,
            expectedPreparedRunRevision: prepared.revision
        )
        let replayed = try manager.startAutonomousRun(
            runID: acceptedRunID,
            projectID: projectID,
            expectedGeneration: generation,
            mission: mission,
            expectedPreparedRunRevision: prepared.revision
        )
        XCTAssertEqual(accepted["run_id"] as? String, acceptedRunID.description)
        XCTAssertEqual(replayed["run_id"] as? String, acceptedRunID.description)
        let storedRun = try await app.projectContexts.repository.autonomousRun(acceptedRunID)
        let durable = try XCTUnwrap(storedRun)
        XCTAssertEqual(
            durable.specification.work.metadata["prepared_run_revision"],
            prepared.revision
        )
        XCTAssertEqual(
            durable.specification.work.metadata["source_snapshot_sha256"],
            prepared.source.snapshotSHA256
        )
        XCTAssertEqual(durable.specification.completionPlan, automaticPlan)
        XCTAssertEqual(
            durable.specification.work.metadata["completion_plan_id"],
            automaticPlan.planID.uuidString.lowercased()
        )
        let operatorSnapshot = try manager.operatorSnapshot(limit: 10)
        let projected = try XCTUnwrap(
            operatorSnapshot.runs.first { $0.runID == acceptedRunID.description }
        )
        XCTAssertEqual(projected.completionPlan, automaticPlan)
        let continuity = try XCTUnwrap(
            operatorSnapshot.continuityReadiness.first { $0.runID == acceptedRunID }
        )
        XCTAssertEqual(continuity.projectID, projectID)
        XCTAssertEqual(continuity.projectGeneration, generation)
        XCTAssertTrue(
            [ManagedContinuityDisplayState.monitoring, .waitingForProvider]
                .contains(continuity.state)
        )
        XCTAssertTrue(continuity.automatic)
        if continuity.state == .waitingForProvider {
            XCTAssertTrue(continuity.detail.contains("waits for the configured provider"))
            XCTAssertEqual(continuity.recoveryAction, .reviewProvider)
        } else {
            XCTAssertTrue(continuity.detail.contains("monitoring"))
            XCTAssertEqual(continuity.recoveryAction, ContinuityRecoveryAction.none)
        }
    }

    func testProjectBoundPreparationPublishesEveryTypedReadinessAndRecoveryState() throws {
        let app = try ForgeApp.bootstrap(home: directory)
        let projectRoot = directory.appendingPathComponent("readiness-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))

        let waiting = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Prepare without a saved model."
        )
        XCTAssertEqual(waiting.readiness, .waitingDependency)
        XCTAssertEqual(waiting.recoveryAction, .configureProvider)
        XCTAssertNil(waiting.descriptor)

        let current = try manager.readProviderConfiguration()
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/readiness-model"
        ))
        let ready = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Prepare all exact run inputs."
        )
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertEqual(ready.recoveryAction, .none)
        XCTAssertNotNil(ready.descriptor)

        let stale = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: ProjectGeneration(generation.rawValue + 1),
            mission: "Refresh stale project state."
        )
        XCTAssertEqual(stale.readiness, .automaticallyPreparing)
        XCTAssertEqual(stale.recoveryAction, .retryPreparation)
        XCTAssertEqual(stale.projectGeneration, generation.rawValue)
        XCTAssertNil(stale.descriptor)

        let missing = manager.inspectAutonomousRunPreparation(
            projectID: ProjectID(),
            expectedGeneration: ProjectGeneration(1),
            mission: "Choose a registered project."
        )
        XCTAssertEqual(missing.readiness, .needsChoice)
        XCTAssertEqual(missing.recoveryAction, .selectProject)

        let permissionChoice = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Reject unknown permissions.",
            allowedTools: ["fixture_unknown_tool"]
        )
        XCTAssertEqual(permissionChoice.readiness, .needsChoice)
        XCTAssertEqual(permissionChoice.recoveryAction, .reviewPermissions)

        try app.config.update(["allowed_roots": []], save: true)
        let authorization = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Require exact project authority."
        )
        XCTAssertEqual(authorization.readiness, .needsAuthorization)
        XCTAssertEqual(authorization.recoveryAction, .authorizeProject)

        let failed = manager.inspectAutonomousRunPreparation(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "  invalid padded instructions  "
        )
        XCTAssertEqual(failed.readiness, .failed)
        XCTAssertEqual(failed.recoveryAction, .retryPreparation)
        XCTAssertNil(failed.descriptor)
    }

    func testProjectToolPermissionRoutesPersistAndDriveManagerPreparation() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        let port = Int.random(in: 29_000...39_000)
        let projectRoot = directory.appendingPathComponent(
            "tool-permission-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try app.config.update([
            "allowed_roots": [projectRoot.path],
            "dashboard": ["port": port],
        ], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = try? manager.stopService()
            app.shutdown()
        }
        let current = try manager.readProviderConfiguration()
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model"
        ))
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try XCTUnwrap(registered["project_id"] as? String)
        let generation = try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        )
        _ = try manager.startService()
        let client = OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )

        let initial = try await client.projectToolPermissions(
            projectID: projectID,
            generation: generation
        )
        XCTAssertEqual(initial.selectionMode, .recommended)
        XCTAssertGreaterThan(initial.tools.count, initial.effectiveToolIDs.count)
        XCTAssertTrue(initial.tools.allSatisfy { !$0.description.isEmpty })
        XCTAssertTrue(initial.tools.contains { $0.category == .files })
        XCTAssertTrue(initial.tools.contains { $0.category == .sourceControl })
        XCTAssertTrue(initial.tools.contains { $0.category == .projectMemory })

        let saved = try await client.updateProjectToolPermissions(
            ManagerToolPermissionUpdate(
                projectID: projectID,
                projectGeneration: generation,
                expectedPreferenceRevision: initial.preferenceRevision,
                selectionMode: .explicit,
                selectedToolIDs: ["fs_read"]
            )
        )
        XCTAssertEqual(saved.selectionMode, .explicit)
        XCTAssertEqual(saved.selectedToolIDs, ["fs_read"])
        XCTAssertEqual(saved.effectiveToolIDs, ["fs_read"])
        let reloaded = try await client.projectToolPermissions(
            projectID: projectID,
            generation: generation
        )
        XCTAssertEqual(reloaded, saved)

        let prepared = manager.inspectAutonomousRunPreparation(
            projectID: ProjectID(try XCTUnwrap(UUID(uuidString: projectID))),
            expectedGeneration: ProjectGeneration(generation),
            mission: "Use only the saved project capability."
        )
        XCTAssertEqual(prepared.readiness, .ready)
        XCTAssertEqual(prepared.descriptor?.allowedTools, ["fs_read"])
        XCTAssertEqual(prepared.descriptor?.toolCatalogRevision, saved.catalogRevision)

        let none = try await client.updateProjectToolPermissions(
            ManagerToolPermissionUpdate(
                projectID: projectID,
                projectGeneration: generation,
                expectedPreferenceRevision: saved.preferenceRevision,
                selectionMode: .explicit,
                selectedToolIDs: []
            )
        )
        XCTAssertTrue(none.effectiveToolIDs.isEmpty)
        let denied = manager.inspectAutonomousRunPreparation(
            projectID: ProjectID(try XCTUnwrap(UUID(uuidString: projectID))),
            expectedGeneration: ProjectGeneration(generation),
            mission: "Do not restore denied capabilities."
        )
        XCTAssertEqual(denied.readiness, .needsChoice)
        XCTAssertEqual(denied.recoveryAction, .reviewPermissions)
        XCTAssertNil(denied.descriptor)
    }

    func testDirectRunArtifactPreparesAndStartsWithoutInlineSourceBody() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { Self.makeInstructionSnapshotsRemovable(app.paths.instructionPackageStoreDir) }
        let port = Int.random(in: 29_000...39_000)
        let projectRoot = directory.appendingPathComponent("artifact-run-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update([
            "allowed_roots": [projectRoot.path],
            "dashboard": ["port": port],
        ], save: true)
        let source = directory.appendingPathComponent("pasted-large-task.txt")
        let instructions = String(repeating: "Apply every late constraint.\n", count: 80_000)
        try instructions.write(to: source, atomically: true, encoding: .utf8)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = try? manager.stopService()
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let current = try manager.readProviderConfiguration()
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/artifact-model"
        ))
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
        _ = try manager.recoverManagedAutonomy()
        _ = try manager.startService()
        let client = OperatorManagerHTTPClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let runID = RunID()
        let imported = try await client.importRunInstructionArtifact(
            projectID: projectID.description,
            generation: generation.rawValue,
            runID: runID.description,
            sourcePath: source.path,
        )
        let digest = imported.contentSHA256
        let bootstrap = imported.mission
        XCTAssertGreaterThan(instructions.utf8.count, 1_048_576)
        XCTAssertLessThanOrEqual(
            bootstrap.utf8.count,
            ProjectInstructionQueueStore.maximumBootstrapSummaryBytes
        )

        let request = OperatorRunStartRequest(
            runID: runID.description,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            assignmentID: nil,
            mission: bootstrap,
            instructionArtifactSHA256: digest,
            providerID: nil,
            adapterID: nil,
            modelKey: nil,
            allowedTools: nil,
            completionGates: nil,
            networkAllowed: nil,
            expectedProviderConfigurationRevision: nil,
            expectedToolCatalogRevision: nil,
            maximumInlineOutputBytes: 64 * 1_024
        )
        let preparation = try await client.prepareRun(request)
        let prepared = try XCTUnwrap(preparation.descriptor)
        XCTAssertEqual(prepared.source.kind, .instructionArtifact)
        XCTAssertEqual(prepared.source.snapshotSHA256, digest)
        XCTAssertEqual(prepared.documents.count, 1)
        XCTAssertTrue(prepared.allowedTools.contains("instruction_catalog"))
        XCTAssertTrue(prepared.allowedTools.contains("instruction_read"))
        _ = try await client.startRun(request.expectingPreparedRevision(prepared.revision))
        let stored = try await app.projectContexts.repository.autonomousRun(runID)
        let durable = try XCTUnwrap(stored)
        XCTAssertEqual(durable.mission, bootstrap)
        XCTAssertEqual(
            durable.specification.work.metadata["source_snapshot_sha256"],
            digest
        )
        let catalog = try ProjectInstructionQueueStore(paths: app.paths).catalogPage(
            contentSHA256: digest,
            projectID: projectID,
            generation: generation,
            runID: runID,
            cursor: 0,
            limit: 10
        )
        XCTAssertEqual(catalog.totalDocuments, 1)
    }

    func testInstructionQueuePersistsSharedPreparedDescriptorIdentity() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { Self.makeInstructionSnapshotsRemovable(app.paths.instructionPackageStoreDir) }
        let projectRoot = directory.appendingPathComponent("queued-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let instruction = directory.appendingPathComponent("queued-instructions.md")
        let instructionData = Data("Inspect the project and complete the queued work.".utf8)
        try instructionData.write(to: instruction, options: .atomic)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            _ = manager.shutdownManagedAutonomy()
            app.shutdown()
        }
        let current = try manager.readProviderConfiguration()
        let saved = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/queue-model"
        ))
        let checkedAt = ISO8601.string(from: app.clock.now())
        let receiptDirectory = app.paths.managedProvidersDir.appendingPathComponent(
            ManagerNode.nativeSessionHostAdapterID,
            isDirectory: true
        )
        try OwnerOnlyAtomicFile.write(
            try JSONSupport.data(from: [
                "schemaVersion": 1,
                "configurationRevision": saved.revision,
                "checkedAt": checkedAt,
                "provider": [
                    "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                    "provider_id": ProviderIntegrationID.lmStudio.rawValue,
                    "health": "contract_valid",
                    "endpoint": saved.endpoint,
                    "credential_configured": false,
                    "api_mode": "managed_provider",
                    "model_key": "fixture/queue-model",
                    "tool_use_capable": true,
                    "contract_fingerprint": String(repeating: "a", count: 64),
                    "last_probe_mode": ManagerProviderProbeMode.contract.rawValue,
                    "last_probe_at": checkedAt,
                ],
            ]),
            to: receiptDirectory.appendingPathComponent("provider-readiness.json")
        )
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        ))
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

        var durable: AutonomousRunRecord?
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while durable == nil, ContinuousClock.now < deadline {
            let queue = try manager.instructionQueue(
                projectID: projectID,
                expectedGeneration: generation
            )
            if let package = (queue["packages"] as? [[String: Any]])?.first,
               let runValue = package["run_id"] as? String,
               let runUUID = UUID(uuidString: runValue) {
                durable = try await app.projectContexts.repository.autonomousRun(RunID(runUUID))
            }
            if durable == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let run = try XCTUnwrap(durable)
        let metadata = run.specification.work.metadata
        XCTAssertEqual(metadata["source_snapshot_sha256"], metadata["instruction_package_sha256"])
        XCTAssertEqual(metadata["continuity_mode"], ContinuityMode.managedAutonomous.rawValue)
        XCTAssertEqual(metadata["provider_configuration_revision"]?.isEmpty, false)
        XCTAssertEqual(metadata["tool_catalog_revision"]?.count, 64)
        XCTAssertEqual(metadata["prepared_run_revision"]?.count, 64)
        XCTAssertEqual(run.modelKey, "fixture/queue-model")
        let automaticPlan = try XCTUnwrap(run.specification.completionPlan)
        XCTAssertEqual(automaticPlan.projectID, projectID)
        XCTAssertEqual(automaticPlan.projectGeneration, generation)
        XCTAssertEqual(automaticPlan.instructionArtifactSHA256, [
            try XCTUnwrap(metadata["instruction_package_sha256"]),
        ])
        XCTAssertEqual(
            metadata["completion_plan_id"],
            automaticPlan.planID.uuidString.lowercased()
        )
    }

    private static func makeInstructionSnapshotsRemovable(_ root: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        var entries: [URL] = []
        for case let entry as URL in enumerator { entries.append(entry) }
        for entry in entries.reversed() {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory == true ? 0o700 : 0o600],
                ofItemAtPath: entry.path
            )
        }
    }

    func testBusyProviderRouteRejectsCredentialBodiesWithoutDispatchingMutations() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let port = Int.random(in: 29000...39000)
        try app.config.update(["dashboard": ["port": port]], save: true)
        let service = ProviderBusyService()
        let registry = HostAdapterRegistry()
        registry.register(manifest: ForgeNativeSessionHostPlugin.manifest,
            configurationFactory: { _ in service }, factory: { _ in throw ContinuityRunError.hostCapabilityUnavailable })
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        _ = try manager.startService()
        defer { _ = try? manager.stopService() }
        let client = OperatorManagerClientRouter(client:
            OperatorManagerHTTPClient(host: "127.0.0.1", port: port,
                credentials: ManagerControlCredentialStore(paths: app.paths)))
        let inventory = Task { try await client.providerModels() }
        for _ in 0..<100 {
            if await service.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await service.entered
        XCTAssertTrue(entered)
        for _ in 0..<8 {
            do {
                _ = try await client.updateProviderConfiguration(ProviderConfigurationUpdate(
                    expectedRevision: "0", endpoint: "http://127.0.0.1:1234", modelKey: nil,
                    credentialAction: .replace, token: UUID().uuidString))
                XCTFail("Busy route accepted a credential mutation")
            } catch let error as OperatorManagerClientError {
                guard case .rejected(status: 409, message: _) = error else { return XCTFail("Wrong admission result") }
            }
        }
        _ = try await inventory.value
        let updates = await service.updates
        XCTAssertEqual(updates, 0)
        _ = try await client.providerConfiguration()
    }

    func testProviderConfigurationRoutesRequireAuthorizationAndClientPersistsCleanSetup() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let port = Int.random(in: 29000...39000)
        try app.config.update(["dashboard": ["port": port]], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        _ = try manager.startService()
        defer { _ = try? manager.stopService() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/manager/provider/configuration"))
        var unauthorized = URLRequest(url: url)
        unauthorized.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: unauthorized)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        unauthorized.httpMethod = "PUT"
        unauthorized.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        unauthorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (body, expectedStatus) in [(Data(repeating: 32, count: 16385), 413),
            (Data("{\"unexpected\":true}".utf8), 400)] {
            unauthorized.httpBody = body
            let (_, rejected) = try await URLSession.shared.data(for: unauthorized)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, expectedStatus)
        }
        let transport = OperatorManagerHTTPClient(host: "127.0.0.1", port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths))
        let client = OperatorManagerClientRouter(client:
            UnavailableOperatorManagerClient(reason: "Waiting for the configured manager"))
        client.replace(with: transport)
        let clean = try await client.providerConfiguration()
        XCTAssertFalse(clean.saved)
        let saved = try await client.updateProviderConfiguration(request(clean.revision))
        XCTAssertTrue(saved.saved)
        let operatorSnapshot = try manager.operatorSnapshot(limit: 10)
        XCTAssertEqual(operatorSnapshot.runPreparation.state, "automatically_preparing")
        XCTAssertEqual(operatorSnapshot.runPreparation.providerID, "lmstudio")
        XCTAssertEqual(operatorSnapshot.runPreparation.adapterID, ManagerNode.nativeSessionHostAdapterID)
        XCTAssertEqual(operatorSnapshot.runPreparation.modelKey, "fixture/tool-model")
        XCTAssertFalse(operatorSnapshot.runPreparation.allowedTools.isEmpty)
        XCTAssertTrue(
            Set(operatorSnapshot.runPreparation.allowedTools).isSubset(of: Set(app.tools.toolNames))
        )
        XCTAssertEqual(
            operatorSnapshot.runPreparation.completionGates,
            [ProjectInstructionQueueStore.builtInCompletionGate]
        )
        XCTAssertFalse(operatorSnapshot.runPreparation.networkAllowed)
        XCTAssertEqual(operatorSnapshot.provider.endpoint, saved.endpoint)
        XCTAssertEqual(operatorSnapshot.provider.modelKey, saved.modelKey)
        let reread = try await client.providerConfiguration()
        XCTAssertEqual(reread, saved)
        do { _ = try await client.updateProviderConfiguration(request(clean.revision)); XCTFail("Stale manager update accepted") }
        catch let error as OperatorManagerClientError {
            guard case .rejected(status: 409, message: _) = error else { return XCTFail("Wrong conflict result") }
        }
        // Production registration retrieves persisted settings on a fresh owner.
        let restarted = ManagerNode(app: app, hostAdapterRegistry: registry)
        XCTAssertEqual(try restarted.readProviderConfiguration(), saved)
        client.replace(with: UnavailableOperatorManagerClient(reason: "Manager connection replaced"))
        do { _ = try await client.providerConfiguration(); XCTFail("The router retained the replaced manager") }
        catch let error as OperatorManagerClientError {
            XCTAssertEqual(error, .disabled("Manager connection replaced"))
        }
        client.replace(with: transport)
        let reconnected = try await client.providerConfiguration()
        XCTAssertEqual(reconnected, saved)
    }

    func testContinuityReadinessPresentationCoversAutomaticAndExternalStates() throws {
        let projectID = ProjectID()
        let runID = RunID()
        let timestamp = "2027-01-15T08:00:00Z"
        func run(
            _ state: AutonomousRunState = .running,
            mode: ContinuityMode = .managedAutonomous,
            errorCode: String? = nil,
            errorSummary: String? = nil
        ) -> AutonomousRunRecord {
            AutonomousRunRecord(
                runID: runID,
                projectID: projectID,
                projectGeneration: .initial,
                assignmentID: nil,
                mission: "Continuity fixture",
                state: state,
                continuityMode: mode,
                providerID: "fixture-provider",
                modelKey: "fixture-model",
                activeSessionID: "predecessor-session",
                activeOperationID: nil,
                specification: AutonomousRunSpecification(
                    allowedTools: [],
                    completionGates: [],
                    work: AutonomousRunWork(metadata: [
                        "adapter_id": "forge.native-session-host"
                    ])
                ),
                completionRequestJSON: nil,
                lastErrorCode: errorCode
                    ?? (state == .blockedConfiguration ? "fixture_blocked" : nil),
                lastErrorSummary: errorSummary
                    ?? (state == .blockedConfiguration
                        ? "Fixture continuity dependency is unavailable." : nil),
                retryAt: nil,
                continuationPending: false,
                revision: 4,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        func operation(
            type: ContinuityCommandType,
            state: ContinuityCommandState,
            checkpointID: String? = nil,
            successor: Bool = false,
            acknowledged: Bool = false
        ) -> ManagerOperatorContinuityReadModel {
            let operationID = UUID()
            let successorRecord = successor ? ProviderSessionRecord(
                sessionID: "successor-session",
                runID: runID,
                projectID: projectID,
                projectGeneration: .initial,
                providerID: "fixture-provider",
                adapterID: "forge.native-session-host",
                modelKey: "fixture-model",
                providerResponseID: "fixture-response",
                predecessorSessionID: "predecessor-session",
                handoffID: checkpointID.flatMap(UUID.init(uuidString:)),
                operationID: operationID,
                idempotencyKey: "fixture-successor",
                bootstrapNonceSHA256: String(repeating: "a", count: 64),
                handoffSHA256: String(repeating: "b", count: 64),
                status: .active,
                accepted: true,
                contextCapacity: 32_768,
                createdAt: timestamp,
                updatedAt: timestamp
            ) : nil
            return ManagerOperatorContinuityReadModel(
                command: ContinuityCommand(
                    commandID: UUID(),
                    operationID: operationID,
                    runID: runID,
                    projectID: projectID,
                    projectGeneration: .initial,
                    type: type,
                    requestedBy: "fixture",
                    reason: "fixture",
                    state: state,
                    idempotencyKey: "fixture-command",
                    payloadSHA256: String(repeating: "c", count: 64),
                    attempt: 1,
                    retryAt: state == .retryWait ? "2027-01-15T08:01:00Z" : nil,
                    lastErrorCode: state == .failed ? "fixture_failure" : nil,
                    lastErrorSummary: state == .failed ? "Fixture rollover failed." : nil,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ),
                run: run(),
                predecessor: nil,
                successor: successorRecord,
                automaticContinuation: nil,
                budgetObservation: nil,
                checkpointID: checkpointID,
                acknowledgementSHA256: acknowledged ? String(repeating: "d", count: 64) : nil
            )
        }

        XCTAssertEqual(
            ManagerNode.continuityPresentation(run: run(), continuity: nil).state,
            .monitoring
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(mode: .externalMCPCompatibility),
                continuity: nil
            ).state,
            .externalCompatibilityOnly
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(run: run(.waitingProvider), continuity: nil).state,
            .waitingForProvider
        )
        let blockedPresentation = ManagerNode.continuityPresentation(
            run: run(
                .blockedConfiguration,
                errorSummary: "Install the required native gate policy or restore its required environment."
            ),
            continuity: nil
        )
        XCTAssertEqual(blockedPresentation.state, .restoring)
        XCTAssertEqual(blockedPresentation.recoveryAction, .none)
        XCTAssertTrue(blockedPresentation.detail.contains("automatically"))
        XCTAssertFalse(blockedPresentation.detail.localizedCaseInsensitiveContains("gate"))
        XCTAssertFalse(blockedPresentation.detail.localizedCaseInsensitiveContains("policy"))
        XCTAssertFalse(blockedPresentation.nextAction.localizedCaseInsensitiveContains("environment"))
        XCTAssertFalse(blockedPresentation.nextAction.localizedCaseInsensitiveContains("install"))
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(
                    .failedRecoverable,
                    errorCode: "provider_unavailable",
                    errorSummary: "LM Studio is unavailable."
                ),
                continuity: nil
            ).recoveryAction,
            .reviewProvider
        )
        let completionPresentation = ManagerNode.continuityPresentation(
            run: run(
                .failedRecoverable,
                errorCode: AutonomyError.completionValidationFailed.code,
                errorSummary: "forge.completion.tests: The selected tests did not pass."
            ),
            continuity: nil
        )
        XCTAssertEqual(completionPresentation.recoveryAction, .reviewRun)
        XCTAssertTrue(completionPresentation.nextAction.contains("named completion check"))
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(type: .checkpoint, state: .queued)
            ).state,
            .savingProgress
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(type: .rollover, state: .queued)
            ).state,
            .rolloverQueued
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(type: .rollover, state: .running)
            ).state,
            .quiescing
        )
        let checkpointID = UUID().uuidString.lowercased()
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(
                    type: .rollover,
                    state: .running,
                    checkpointID: checkpointID
                )
            ).state,
            .creatingSuccessor
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(
                    type: .rollover,
                    state: .running,
                    checkpointID: checkpointID,
                    successor: true
                )
            ).state,
            .restoring
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(
                    type: .rollover,
                    state: .running,
                    checkpointID: checkpointID,
                    successor: true,
                    acknowledged: true
                )
            ).state,
            .continuing
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(type: .rollover, state: .retryWait)
            ).recoveryAction,
            .retryAutomatically
        )
        XCTAssertEqual(
            ManagerNode.continuityPresentation(
                run: run(),
                continuity: operation(type: .rollover, state: .failed)
            ).state,
            .blocked
        )

        let wireFixture = ManagerContinuityReadiness(
            projectID: projectID,
            projectGeneration: .initial,
            runID: runID,
            state: .monitoring,
            automatic: true,
            detail: "Automatic continuity is monitoring this task.",
            capacityTokens: 32_768,
            usedTokens: 9_216,
            remainingTokens: 23_552,
            confidence: 0.95,
            source: "fixture",
            recoveryAction: ContinuityRecoveryAction.none
        )
        let encoded = try JSONEncoder().encode(wireFixture)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["project_id"] as? String, projectID.description)
        XCTAssertEqual((object["project_generation"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(object["run_id"] as? String, runID.description)
        XCTAssertNil(object["projectID"])
        XCTAssertEqual(try JSONDecoder().decode(ManagerContinuityReadiness.self, from: encoded), wireFixture)
    }
}

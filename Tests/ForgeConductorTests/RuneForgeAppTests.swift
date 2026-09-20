import AppKit
import Foundation
import XCTest
import ForgeConductorCore
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class RuneForgeAppTests: XCTestCase {
    func testNativePickerAcceptsOneFileOrFolderWithoutContentTypeAllowlist() {
        let panel = RuneForgePolicyPicker.makePanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertTrue(panel.allowedContentTypes.isEmpty)
        XCTAssertEqual(panel.prompt, "Add Development Policy")
        XCTAssertEqual(
            panel.message,
            "Choose any file or folder containing development policy, governance, or guidance."
        )
    }

    func testTestSelectionHookRequiresExplicitUITestLaunch() {
        let path = "/tmp/rune-policy-selection.opaque"
        XCTAssertEqual(
            RuneForgePolicyPicker.select(
                arguments: ["Forge Conductor", "--uitesting"],
                environment: [RuneForgePolicyPicker.testSelectionEnvironmentKey: path]
            )?.path,
            path
        )
    }

    func testSelectedSourceAppearsImmediatelyAndSurvivesDeferredManager() async throws {
        let client = DeferredRuneForgeClient()
        let viewModel = RuneForgeViewModel(client: client)
        let source = URL(fileURLWithPath: "/tmp/policy.unsupported-format")

        viewModel.addPolicySource(source)

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy.unsupported-format")
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .accepted)
        XCTAssertTrue(viewModel.sources.first?.isOptimistic == true)

        try await waitUntil { viewModel.errorMessage != nil }
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .refreshPending)
        XCTAssertTrue(viewModel.sources.first?.latestObservation?.contains("remains visible") == true)
    }

    func testSuccessfulCatalogConfirmationReplacesOptimisticSource() async throws {
        let source = DevelopmentPolicySource(
            displayName: "policy-folder",
            selectedPath: "/tmp/policy-folder",
            rootKind: .directory,
            interpretationState: .cataloging,
            latestObservation: "Directory discovery is in progress."
        )
        let client = ConfirmingRuneForgeClient(source: source)
        let viewModel = RuneForgeViewModel(client: client)

        viewModel.addPolicySource(URL(fileURLWithPath: source.selectedPath, isDirectory: true))
        try await waitUntil { viewModel.sources.first?.sourceID == source.id }

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertFalse(viewModel.sources[0].isOptimistic)
        XCTAssertEqual(viewModel.sources[0].interpretationState, .cataloging)
        XCTAssertEqual(
            RuneForgeViewModel.sourceStateTitle(viewModel.sources[0].interpretationState),
            "Cataloging"
        )
    }

    func testOptimisticSourcePresentationIsBounded() {
        let viewModel = RuneForgeViewModel(client: DeferredRuneForgeClient())

        for index in 0...RuneForgeViewModel.maximumSources {
            viewModel.addPolicySource(
                URL(fileURLWithPath: "/tmp/policy-\(index).opaque")
            )
        }

        XCTAssertEqual(viewModel.sources.count, RuneForgeViewModel.maximumSources)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy-100.opaque")
        XCTAssertNil(
            viewModel.sources.first(where: { $0.displayName == "policy-0.opaque" })
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { return XCTFail("condition timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct DeferredRuneForgeClient: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await Task.sleep(for: .milliseconds(25))
        throw URLError(.cannotConnectToHost)
    }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

private struct ConfirmingRuneForgeClient: RuneForgeManagerClientProtocol {
    let source: DevelopmentPolicySource

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

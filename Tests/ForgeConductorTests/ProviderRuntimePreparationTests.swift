import XCTest
@testable import ForgeConductorCore
#if SWIFT_PACKAGE
@testable import ForgeNativeSessionHostPlugin
#endif

final class ProviderRuntimePreparationTests: XCTestCase {
    func testLiveConnectAndCheckPersistsAndReusesExactReadiness() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelKey = environment["FORGE_LIVE_LMSTUDIO_MODEL"], !modelKey.isEmpty else {
            throw XCTSkip("Set FORGE_LIVE_LMSTUDIO_MODEL to run live provider preparation")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-preparation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        let clean = try manager.readProviderConfiguration()
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: clean.revision,
            endpoint: environment["FORGE_LIVE_LMSTUDIO_BASE_URL"]
                ?? "http://127.0.0.1:1234",
            modelKey: modelKey
        ))

        let first = try manager.connectAndCheckProvider()
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(first.recoveryAction, .none)
        XCTAssertEqual(first.provider?.health, "contract_valid")
        XCTAssertEqual(first.configuration.modelKey, modelKey)

        let second = try manager.connectAndCheckProvider()
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(second.configuration.revision, first.configuration.revision)
        XCTAssertEqual(second.provider?.contractFingerprint, first.provider?.contractFingerprint)
        XCTAssertTrue(second.detail.contains("current"))

        let readiness = home.appendingPathComponent(
            "managed-providers/forge.native-session-host/provider-readiness.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: readiness.path))
        let bytes = try Data(contentsOf: readiness)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("token"))
    }

    func testOnlyCompatibleLoadedModelIsSelectedAndSelectionIsIdempotent() {
        let configuration = ProviderConfigurationSnapshot(
            revision: "fixture-revision",
            endpoint: "http://127.0.0.1:1234",
            modelKey: nil,
            credentialConfigured: false,
            saved: true
        )
        let inventory = ProviderModelInventory(revision: configuration.revision, models: [
            ProviderAvailableModel(key: "fixture/unloaded", loaded: false, toolUseCapable: true),
            ProviderAvailableModel(key: "fixture/incompatible", loaded: true, toolUseCapable: false),
            ProviderAvailableModel(key: "fixture/ready", loaded: true, toolUseCapable: true),
        ])

        let first = ProviderModelSelectionResolver.resolve(
            configuration: configuration,
            inventory: inventory
        )
        let second = ProviderModelSelectionResolver.resolve(
            configuration: configuration,
            inventory: inventory
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.modelKey, "fixture/ready")
        XCTAssertEqual(first.recoveryAction, .none)
    }

    func testPinnedModelIsNeverSilentlyReplaced() {
        let configuration = ProviderConfigurationSnapshot(
            revision: "fixture-revision",
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/pinned",
            credentialConfigured: false,
            saved: true
        )
        let inventory = ProviderModelInventory(revision: configuration.revision, models: [
            ProviderAvailableModel(key: "fixture/other", loaded: true, toolUseCapable: true),
        ])

        let selection = ProviderModelSelectionResolver.resolve(
            configuration: configuration,
            inventory: inventory
        )
        XCTAssertNil(selection.modelKey)
        XCTAssertEqual(selection.recoveryAction, .selectModel)
        XCTAssertTrue(selection.detail.contains("pinned model"))
    }

    func testProviderPreparationEncodingCannotContainCredentialMaterial() throws {
        let marker = "transient-secret-marker"
        let result = ManagerProviderPreparationResult(
            state: .actionRequired,
            recoveryAction: .supplyCredential,
            detail: "LM Studio requires a credential.",
            configuration: ProviderConfigurationSnapshot(
                revision: "fixture-revision",
                endpoint: "http://127.0.0.1:1234",
                modelKey: "fixture/model",
                credentialConfigured: true,
                saved: true
            )
        )
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains(marker))
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertTrue(encoded.contains("credentialConfigured"))
    }

    func testMissingPythonDoesNotBlockSwiftTask() throws {
        let capabilities = fixtureCapabilities(python: .notInstalled)
        let resolved = RuntimeRequirementResolver.resolve(
            input: RuntimeRequirementInput(
                selectedTools: ["fs_read", "fs_edit"],
                projectMetadata: ["project.language": "swift"]
            ),
            capabilities: capabilities
        )
        let python = try XCTUnwrap(resolved.first { $0.runtime == .python })
        XCTAssertEqual(python.requirement, .notNeeded)
        XCTAssertEqual(python.availability, .notInstalled)
        XCTAssertFalse(python.blocksTask)
        XCTAssertNil(python.recoveryAction)
    }

    func testRequiredMissingPythonReturnsOneSpecificAction() throws {
        let resolved = RuntimeRequirementResolver.resolve(
            input: RuntimeRequirementInput(selectedTools: ["python.run"]),
            capabilities: fixtureCapabilities(python: .notInstalled)
        )
        let python = try XCTUnwrap(resolved.first { $0.runtime == .python })
        XCTAssertEqual(python.requirement, .required)
        XCTAssertEqual(python.availability, .notInstalled)
        XCTAssertTrue(python.blocksTask)
        XCTAssertEqual(
            python.recoveryAction,
            "Install or configure Python 3, then refresh runtime readiness."
        )
        XCTAssertEqual(resolved.compactMap(\.recoveryAction).count, 1)
    }

    func testNilExecutablePathDoesNotManufactureNotInstalledStatus() {
        let capability = RuntimeExecutableCapability(
            available: false,
            executablePath: nil,
            required: false
        )
        XCTAssertEqual(capability.probeState, .unknown)
    }

    func testShellPolicyDisablesOnlyShellRuntimesAndUsesExactRecovery() throws {
        let resolved = RuntimeRequirementResolver.resolve(
            input: RuntimeRequirementInput(
                selectedTools: ["bash.run"],
                shellPolicyEnabled: false
            ),
            capabilities: fixtureCapabilities(python: .available)
        )
        let direct = try XCTUnwrap(resolved.first { $0.runtime == .directProcess })
        let bash = try XCTUnwrap(resolved.first { $0.runtime == .bash })
        XCTAssertEqual(direct.availability, .available)
        XCTAssertEqual(bash.availability, .disabledByPolicy)
        XCTAssertEqual(
            bash.recoveryAction,
            "Enable the application-wide shell policy, then refresh runtime readiness."
        )
    }

    private func fixtureCapabilities(
        python: RuntimeExecutableProbeState
    ) -> RuntimeCapabilities {
        func capability(
            _ state: RuntimeExecutableProbeState
        ) -> RuntimeExecutableCapability {
            RuntimeExecutableCapability(
                available: state == .available,
                executablePath: state == .available ? "/fixture/runtime" : nil,
                required: false,
                probeState: state
            )
        }
        return RuntimeCapabilities(
            directProcess: capability(.available),
            zsh: capability(.available),
            bash: capability(.available),
            python: capability(python),
            powershell: capability(.notInstalled),
            maximumConcurrentJobs: 2,
            maximumCPUHeavyJobs: 1,
            maximumInlineOutputBytes: 65_536,
            maximumArtifactBytesPerJob: 1_048_576,
            maximumArtifactBytesPerProject: 2_097_152,
            maximumArtifactBytesGlobal: 4_194_304,
            maximumRetainedArtifactJobsPerProject: 8
        )
    }
}

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
        let prepared = try await client.prepareRun(startRequest)
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
        _ = try manager.updateProviderConfiguration(ProviderConfigurationUpdate(
            expectedRevision: current.revision,
            endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/queue-model"
        ))
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
}

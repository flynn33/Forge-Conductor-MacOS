// NativeSessionHostPluginTests.swift
// Verifies the native host contract, autonomous rollover, recovery, bounds, and privacy.

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private actor ScriptedNativeTransport: NativeSessionTransport {
    enum Mode: Sendable {
        case normal
        case rateLimit(Int)
        case malformedAcknowledgement
        case oversizedChunk
        case deadline
    }

    private var mode: Mode
    private var createAttempts = 0
    private var createEffects: [String: NativeTransportSession] = [:]
    private var cancelled: Set<String> = []

    init(mode: Mode) { self.mode = mode }

    func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession {
        createAttempts += 1
        if case .deadline = mode { throw NativeHostPluginError.deadlineExceeded }
        if case .rateLimit(let failures) = mode, createAttempts <= failures {
            throw NativeHostPluginError.rateLimited(retryNanoseconds: 0)
        }
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = createEffects[request.idempotencyKey] { return existing }
        let created = NativeTransportSession(
            providerSessionID: "provider-\(request.idempotencyKey)", model: "fixture-model"
        )
        createEffects[request.idempotencyKey] = created
        return created
    }

    func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse {
        switch mode {
        case .malformedAcknowledgement:
            return NativeBootstrapResponse(chunks: [Data("not-json".utf8)])
        case .oversizedChunk:
            return NativeBootstrapResponse(
                chunks: [Data(repeating: 0x61, count: ForgeNativeSessionHostAdapter.maximumChunkBytes + 1)]
            )
        case .deadline:
            throw NativeHostPluginError.deadlineExceeded
        default:
            return NativeBootstrapResponse(chunks: [try JSONSupport.data(from: [
                "handoff_id": request.handoffID,
                "successor_session_id": request.successorSessionID,
            ])], inputTokens: 100, outputTokens: 8)
        }
    }

    func cancel(operationID: String, providerSessionID: String?) async {
        cancelled.insert(operationID)
    }

    func stats() -> (attempts: Int, effects: Int, cancellations: Int) {
        (createAttempts, createEffects.count, cancelled.count)
    }
}

private struct FixtureManagedAuthorization: LMStudioAuthorizationProviding {
    func bearerToken() async throws -> String? { "fixture-token" }
}

#if SWIFT_PACKAGE
private actor ScriptedManagedTransport: LMStudioManagedTransporting {
    enum Mode: Sendable {
        case normal
        case ambiguousFirstResponse
        case unauthorized
    }

    private let mode: Mode
    private let ledgerURL: URL
    private var attempts = 0
    private var receipts: [String: LMStudioResponseTurn] = [:]
    private var sawPersistedIntent = false

    init(mode: Mode, ledgerURL: URL) {
        self.mode = mode
        self.ledgerURL = ledgerURL
    }

    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(
            modelKey: "fixture/tool-model",
            loadedInstanceID: "fixture/tool-model@32768",
            contextLength: 32_768,
            maximumContextLength: 131_072,
            parallelism: 1,
            flashAttention: true,
            trainedForToolUse: true,
            streamingVerified: true,
            functionToolContractVerified: true,
            usageReportingVerified: true,
            capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "resp_lms_scripted_probe"
        )
    }

    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        attempts += 1
        if let ledgerText = try? String(contentsOf: ledgerURL, encoding: .utf8),
           ledgerText.contains("\"status\":\"intent\""),
           !ledgerText.contains(request.idempotencyKey) {
            sawPersistedIntent = true
        }
        if case .unauthorized = mode { throw LMStudioProviderError.unauthorized }
        let turn = try Self.turn(for: request)
        receipts[request.idempotencyKey] = turn
        if case .ambiguousFirstResponse = mode, attempts == 1 {
            throw LMStudioProviderError.deadlineExceeded(phase: "total")
        }
        return turn
    }

    func continueSession(
        _ request: LMStudioContinuationRequest
    ) async throws -> LMStudioResponseTurn {
        throw LMStudioProviderError.invalidConfiguration("continuation is not part of this fixture")
    }

    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        receipts[key]
    }

    func cancel(operationID: String) async {}

    func stats() -> (attempts: Int, sawPersistedIntent: Bool) {
        (attempts, sawPersistedIntent)
    }

    private static func turn(for request: LMStudioRootRequest) throws -> LMStudioResponseTurn {
        guard let data = request.userInput.data(using: .utf8),
              let handoff = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = handoff["project"] as? [String: Any],
              let run = handoff["run"] as? [String: Any],
              let bootstrap = handoff["bootstrap"] as? [String: Any],
              let integrity = handoff["integrity"] as? [String: Any],
              let operationID = handoff["operation_id"] as? String,
              let handoffID = handoff["handoff_id"] as? String,
              let projectID = project["project_id"] as? String,
              let generation = project["generation"] as? Int,
              let runID = run["run_id"] as? String,
              let version = bootstrap["acknowledgement_contract_version"] as? Int,
              let nonce = bootstrap["nonce"] as? String,
              let checksum = integrity["content_sha256"] as? String else {
            throw LMStudioProviderError.malformedResponse("fixture handoff is incomplete")
        }
        let acknowledgement: [String: Any] = [
            "acknowledgement_contract_version": version,
            "project_id": projectID,
            "project_generation": generation,
            "run_id": runID,
            "operation_id": operationID.lowercased(),
            "handoff_id": handoffID.lowercased(),
            "handoff_sha256": checksum,
            "nonce": nonce,
            "accepted": true,
        ]
        let arguments = try JSONSupport.canonicalJSON(acknowledgement)
        return LMStudioResponseTurn(
            responseID: "resp_lms_scripted_" + operationID.replacingOccurrences(of: "-", with: ""),
            previousResponseID: nil,
            model: request.modelKey ?? "fixture/tool-model",
            status: "completed",
            assistantText: "",
            functionCalls: [LMStudioFunctionCall(
                itemID: "fc_lms_scripted_ack",
                callID: "call_lms_scripted_ack",
                name: "forge_continuity_ack",
                arguments: arguments
            )],
            usage: LMStudioUsage(inputTokens: 640, outputTokens: 48, totalTokens: 688)
        )
    }
}
#endif

final class NativeSessionHostPluginTests: XCTestCase {
#if SWIFT_PACKAGE
    func testLMStudioErrorsExposeProviderNeutralFailureDisposition() {
        let cases: [(LMStudioProviderError, ManagedProviderFailureDisposition, String)] = [
            (.invalidConfiguration("fixture"), .blockedConfiguration, "lmstudio_invalid_configuration"),
            (.unauthorized, .blockedConfiguration, "lmstudio_unauthorized"),
            (.providerUnavailable, .waitingProvider, "lmstudio_provider_unavailable"),
            (.deadlineExceeded(phase: "idle"), .waitingProvider, "lmstudio_deadline_exceeded"),
            (.contextOverflow, .contextOverflow, "lmstudio_context_overflow"),
            (.responseTruncated, .failedRecoverable, "lmstudio_response_truncated"),
            (.cancelled, .cancelled, "lmstudio_cancelled"),
            (.malformedResponse("fixture"), .failedTerminal, "lmstudio_malformed_response"),
        ]
        for (error, disposition, code) in cases {
            XCTAssertEqual(error.managedProviderFailureDisposition, disposition)
            XCTAssertEqual(error.managedProviderFailureCode, code)
        }
        let rateLimit = LMStudioProviderError.rateLimited(retryNanoseconds: 90_000_000_000)
        XCTAssertEqual(rateLimit.managedProviderRetryDelay, 60)
    }
#endif

    func testProductionRegistrationFailsClosedWithoutProviderConfiguration() throws {
        let root = temporaryRoot("registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        XCTAssertEqual(registry.manifests, [ForgeNativeSessionHostPlugin.manifest])
        XCTAssertThrowsError(try registry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier, storageDirectory: root
        )) { error in
            guard case ContinuityRunError.hostCapabilityUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testConfiguredProductionRegistrationCannotYieldSyntheticV1Session() async throws {
        let root = temporaryRoot("configured-registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = HostAdapterRegistry()
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!, modelKey: "fixture/tool-model"
        )
        ForgeNativeSessionHostPlugin.register(in: registry) { _ in configuration }
        let adapter = try registry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier, storageDirectory: root
        )
        XCTAssertTrue(adapter is LMStudioManagedSessionHostAdapter)
        XCTAssertNotNil(adapter as? any SessionHostAdapterV2)
        XCTAssertFalse(adapter is ForgeNativeSessionHostAdapter)
        XCTAssertNotEqual(
            String(reflecting: Swift.type(of: adapter)),
            String(reflecting: LocalLogicalSessionTransport.self)
        )
        XCTAssertFalse(adapter.identifier.lowercased().hasPrefix("native-"))
        XCTAssertFalse(adapter.identifier.lowercased().hasPrefix("forge-logical-session"))
        do {
            _ = try await adapter.createSession(SessionCreationRequest(
                operationID: UUID().uuidString.lowercased(),
                projectID: UUID().uuidString.lowercased(),
                predecessorSessionID: "provider-predecessor",
                idempotencyKey: "configured-production"
            ))
            XCTFail("V1 must not fabricate a provider session before fresh-root bootstrap")
        } catch ContinuityRunError.hostCapabilityUnavailable {}
    }

    func testProductionRegistrationLoadsBoundedProviderFile() throws {
        let root = temporaryRoot("provider-file")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "base_url": "https://lmstudio.fixture",
            "model_key": "fixture/tool-model",
        ], options: [.sortedKeys])
        try data.write(
            to: root.appendingPathComponent(LMStudioProviderConfiguration.fileName),
            options: .atomic
        )

        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let adapter = try registry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier, storageDirectory: root
        )
        XCTAssertTrue(adapter is LMStudioManagedSessionHostAdapter)
    }

    func testProductionRegistrationUsesKeychainAuthorizationForConfiguredReference() async throws {
        let root = temporaryRoot("provider-authorization")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!,
            modelKey: "fixture/tool-model",
            keychainTokenReference: "fixture-keychain-reference"
        )

        let productionRegistry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: productionRegistry) { _ in configuration }
        let productionAdapter = try productionRegistry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        XCTAssertNotNil(productionAdapter as? any SessionHostAdapterV2)

        let injectedRegistry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(
            in: injectedRegistry,
            configurationSource: { _ in configuration },
            authorizationSource: { _, _ in FixtureManagedAuthorization() }
        )
        let adapter = try injectedRegistry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        XCTAssertNotNil(adapter as? any SessionHostAdapterV2)

        let credential = try LMStudioKeychainAuthorization(
            reference: "fixture-keychain-reference"
        ) { reference in
            reference == "fixture-keychain-reference" ? Data("fixture-token".utf8) : nil
        }
        let resolvedToken = try await credential.bearerToken()
        XCTAssertEqual(resolvedToken, "fixture-token")

        let privateReference = "private-keychain-reference"
        let unavailable = try LMStudioKeychainAuthorization(reference: privateReference) { _ in
            throw NSError(domain: "KeychainFixture", code: 1)
        }
        do {
            _ = try await unavailable.bearerToken()
            XCTFail("unavailable Keychain item must fail closed")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertFalse(description.contains(privateReference))
            XCTAssertFalse(description.contains("KeychainFixture"))
            XCTAssertTrue(description.contains("could not be accessed"))
        }
    }

#if SWIFT_PACKAGE
    func testV2FreshRootReceiptPersistsAndReplaysWithoutSyntheticIdentity() async throws {
        let root = temporaryRoot("v2-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try makeV2Transport()
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let fixture = try makeV2Fixture(
            mission: "Continue the bounded host fixture.",
            idempotencyKey: "v2-success-private-key"
        )

        let capabilities = try await adapter.capabilitiesV2()
        XCTAssertTrue(capabilities.atomicCreateAndBootstrap)
        XCTAssertTrue(capabilities.freshRoot)
        XCTAssertTrue(capabilities.usageReporting)
        XCTAssertTrue(capabilities.idempotencyLookup)
        XCTAssertTrue(capabilities.projectGenerationFencing)

        let receipt = try await adapter.createAndBootstrap(
            request: fixture.request,
            handoffJSON: fixture.handoffJSON,
            challenge: fixture.challenge
        )
        XCTAssertTrue(receipt.providerResponseID.hasPrefix("resp_lms_v2_"))
        XCTAssertFalse(receipt.providerResponseID.hasPrefix("native-"))
        XCTAssertNil(receipt.providerResponseID.range(of: "forge-logical-session"))
        XCTAssertEqual(receipt.acknowledgement.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.acknowledgement.projectID, fixture.request.projectID)
        XCTAssertEqual(
            receipt.acknowledgement.projectGeneration,
            fixture.request.projectGeneration
        )
        XCTAssertEqual(receipt.acknowledgement.runID, fixture.request.runID)
        XCTAssertEqual(receipt.acknowledgement.handoffID, fixture.handoffID)
        XCTAssertEqual(receipt.acknowledgement.handoffSHA256, fixture.handoffSHA256)
        XCTAssertEqual(receipt.acknowledgement.nonce, fixture.challenge.nonce)
        XCTAssertTrue(receipt.acknowledgement.accepted)
        XCTAssertEqual(receipt.usage?.capacity, 32_768)
        XCTAssertEqual(receipt.usage?.used, 688)

        let ledgerURL = root.appendingPathComponent("native-session-ledger.json")
        let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledgerText.contains(fixture.request.idempotencyKey))
        XCTAssertFalse(ledgerText.contains("Continue the bounded host fixture."))
        XCTAssertLessThanOrEqual(
            ledgerText.utf8.count,
            LMStudioManagedSessionHostAdapterV2.maximumLedgerBytes
        )
        let ledgerObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ledgerText.utf8)) as? [String: Any]
        )
        let persistedRecord = try XCTUnwrap(
            (ledgerObject["records"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(persistedRecord["provider_version"] as? String, "0.3.fixture")
        XCTAssertEqual(
            (persistedRecord["provider_capability_fingerprint_sha256"] as? String)?.count,
            64
        )

        let restarted = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: try makeV2Transport()
        )
        let restored = try await restarted.receipt(
            forIdempotencyKey: fixture.request.idempotencyKey
        )
        XCTAssertEqual(restored, receipt)
        let replay = try await restarted.createAndBootstrap(
            request: fixture.request,
            handoffJSON: fixture.handoffJSON,
            challenge: fixture.challenge
        )
        XCTAssertEqual(replay, receipt)
    }

    func testV2TerminalLedgerCompactionRetainsIdempotentReconciliation() async throws {
        let root = temporaryRoot("v2-compaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try makeV2Transport()
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        var fixtures: [V2Fixture] = []
        var receipts: [BootstrapReceipt] = []
        for index in 0..<4 {
            let fixture = try makeV2Fixture(
                mission: "Compact terminal receipt \(index).",
                idempotencyKey: "v2-compaction-private-key-\(index)"
            )
            fixtures.append(fixture)
            receipts.append(try await adapter.createAndBootstrap(
                request: fixture.request,
                handoffJSON: fixture.handoffJSON,
                challenge: fixture.challenge
            ))
        }

        let compacted = try await adapter.compactTerminalLedger(
            retainingRecentTerminalRecords: 1
        )
        XCTAssertEqual(compacted, 3)
        let ledgerURL = root.appendingPathComponent("native-session-ledger.json")
        let data = try Data(contentsOf: ledgerURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 1)
        let reconciliation = try XCTUnwrap(
            object["reconciliation_records"] as? [[String: Any]]
        )
        XCTAssertEqual(reconciliation.count, 3)
        let retainedKeys = Set(reconciliation.compactMap {
            $0["idempotency_key_sha256"] as? String
        })
        let allKeyDigests = Set(fixtures.map {
            JSONSupport.sha256Hex($0.request.idempotencyKey)
        })
        XCTAssertEqual(retainedKeys.count, 3)
        XCTAssertTrue(retainedKeys.isSubset(of: allKeyDigests))
        for fixture in fixtures {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(
                fixture.request.idempotencyKey
            ))
        }

        let restarted = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let compactedIndex = try XCTUnwrap(fixtures.firstIndex {
            retainedKeys.contains(JSONSupport.sha256Hex($0.request.idempotencyKey))
        })
        let restored = try await restarted.receipt(
            forIdempotencyKey: fixtures[compactedIndex].request.idempotencyKey
        )
        XCTAssertEqual(restored, receipts[compactedIndex])
        let replay = try await restarted.createAndBootstrap(
            request: fixtures[compactedIndex].request,
            handoffJSON: fixtures[compactedIndex].handoffJSON,
            challenge: fixtures[compactedIndex].challenge
        )
        XCTAssertEqual(replay, receipts[compactedIndex])

        let directoryItems = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            directoryItems.filter { $0.lastPathComponent.hasPrefix("native-session-ledger") }
                .map(\.lastPathComponent),
            ["native-session-ledger.json"]
        )
    }

    func testV2CrashRetryReconcilesPersistedIntentByIdempotencyKey() async throws {
        let root = temporaryRoot("v2-reconcile")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("native-session-ledger.json")
        let transport = ScriptedManagedTransport(
            mode: .ambiguousFirstResponse,
            ledgerURL: ledgerURL
        )
        let fixture = try makeV2Fixture(
            mission: "Recover the ambiguous provider result.",
            idempotencyKey: "v2-reconcile-private-key"
        )
        let first = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        do {
            _ = try await first.createAndBootstrap(
                request: fixture.request,
                handoffJSON: fixture.handoffJSON,
                challenge: fixture.challenge
            )
            XCTFail("the first ambiguous result must enter reconciliation")
        } catch {
            XCTAssertEqual(
                error as? LMStudioProviderError,
                .deadlineExceeded(phase: "total")
            )
        }
        let failedStatus = await first.candidateStatus(
            forIdempotencyKey: fixture.request.idempotencyKey
        )
        XCTAssertEqual(failedStatus, "retryable_failure")

        let restarted = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let receipt = try await restarted.createAndBootstrap(
            request: fixture.request,
            handoffJSON: fixture.handoffJSON,
            challenge: fixture.challenge
        )
        XCTAssertTrue(receipt.acknowledgement.accepted)
        let stats = await transport.stats()
        XCTAssertEqual(stats.attempts, 1)
        XCTAssertTrue(stats.sawPersistedIntent)
        let acceptedStatus = await restarted.candidateStatus(
            forIdempotencyKey: fixture.request.idempotencyKey
        )
        XCTAssertEqual(acceptedStatus, "accepted")
    }

    func testV2QuarantinesAcknowledgementMismatchDuplicateAndSyntheticCandidate() async throws {
        let mismatchRoot = temporaryRoot("v2-mismatch")
        defer { try? FileManager.default.removeItem(at: mismatchRoot) }
        let mismatch = try makeV2Fixture(
            mission: "fixture-mismatch-nonce",
            idempotencyKey: "v2-mismatch"
        )
        let mismatchAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: mismatchRoot,
            transport: try makeV2Transport()
        )
        do {
            _ = try await mismatchAdapter.createAndBootstrap(
                request: mismatch.request,
                handoffJSON: mismatch.handoffJSON,
                challenge: mismatch.challenge
            )
            XCTFail("mismatched acknowledgement must be quarantined")
        } catch SessionHostAdapterV2Error.acknowledgementMismatch {}
        let mismatchStatus = await mismatchAdapter.candidateStatus(
            forIdempotencyKey: mismatch.request.idempotencyKey
        )
        XCTAssertEqual(mismatchStatus, "quarantined")

        let duplicateRoot = temporaryRoot("v2-duplicate")
        defer { try? FileManager.default.removeItem(at: duplicateRoot) }
        let duplicateAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: duplicateRoot,
            transport: try makeV2Transport()
        )
        let accepted = try makeV2Fixture(
            mission: "Accept one successor.",
            idempotencyKey: "v2-duplicate-a"
        )
        _ = try await duplicateAdapter.createAndBootstrap(
            request: accepted.request,
            handoffJSON: accepted.handoffJSON,
            challenge: accepted.challenge
        )
        let duplicateRequest = SessionCreationRequestV2(
            operationID: accepted.request.operationID,
            projectID: accepted.request.projectID,
            projectGeneration: accepted.request.projectGeneration,
            runID: accepted.request.runID,
            predecessorSessionID: accepted.request.predecessorSessionID,
            modelKey: accepted.request.modelKey,
            idempotencyKey: "v2-duplicate-b"
        )
        do {
            _ = try await duplicateAdapter.createAndBootstrap(
                request: duplicateRequest,
                handoffJSON: accepted.handoffJSON,
                challenge: accepted.challenge
            )
            XCTFail("a later candidate for one operation must be quarantined")
        } catch SessionHostAdapterV2Error.candidateQuarantined {}
        let duplicateStatus = await duplicateAdapter.candidateStatus(
            forIdempotencyKey: "v2-duplicate-b"
        )
        XCTAssertEqual(duplicateStatus, "quarantined")

        let syntheticRoot = temporaryRoot("v2-synthetic")
        defer { try? FileManager.default.removeItem(at: syntheticRoot) }
        let synthetic = try makeV2Fixture(
            mission: "fixture-synthetic-provider-id",
            idempotencyKey: "v2-synthetic"
        )
        let syntheticAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: syntheticRoot,
            transport: try makeV2Transport()
        )
        do {
            _ = try await syntheticAdapter.createAndBootstrap(
                request: synthetic.request,
                handoffJSON: synthetic.handoffJSON,
                challenge: synthetic.challenge
            )
            XCTFail("synthetic provider identity must not be accepted")
        } catch LMStudioProviderError.syntheticProviderIdentifier {}
        let syntheticReceipt = try await syntheticAdapter.receipt(
            forIdempotencyKey: synthetic.request.idempotencyKey
        )
        XCTAssertNil(syntheticReceipt)
        let syntheticStatus = await syntheticAdapter.candidateStatus(
            forIdempotencyKey: synthetic.request.idempotencyKey
        )
        XCTAssertEqual(syntheticStatus, "quarantined")
    }

    func testV2RejectsIdentityChecksumNonceAndSecretBeforeProvider() async throws {
        let root = temporaryRoot("v2-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = ScriptedManagedTransport(
            mode: .normal,
            ledgerURL: root.appendingPathComponent("native-session-ledger.json")
        )
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let fixture = try makeV2Fixture(
            mission: "Validate exact identity.",
            idempotencyKey: "v2-invalid"
        )
        let invalidPayloads = try [
            mutateV2Handoff(fixture.handoffJSON, recomputeChecksum: false) {
                $0["mission"] = "checksum changed"
            },
            mutateV2Handoff(fixture.handoffJSON) { object in
                var project = object["project"] as! [String: Any]
                project["generation"] = 2
                object["project"] = project
            },
            mutateV2Handoff(fixture.handoffJSON) {
                $0["operation_id"] = UUID().uuidString.lowercased()
            },
            mutateV2Handoff(fixture.handoffJSON) { object in
                var run = object["run"] as! [String: Any]
                run["run_id"] = UUID().uuidString.lowercased()
                object["run"] = run
            },
            mutateV2Handoff(fixture.handoffJSON) { object in
                var bootstrap = object["bootstrap"] as! [String: Any]
                bootstrap["nonce"] = String(repeating: "x", count: 48)
                object["bootstrap"] = bootstrap
            },
            mutateV2Handoff(fixture.handoffJSON) { object in
                var predecessor = object["predecessor_session"] as! [String: Any]
                predecessor["unexpected"] = "schema-invalid"
                object["predecessor_session"] = predecessor
            },
            mutateV2Handoff(fixture.handoffJSON) {
                $0["mission"] = "api_key=private-fixture-value" // Example credential fixture.
            },
        ]
        for payload in invalidPayloads {
            do {
                _ = try await adapter.createAndBootstrap(
                    request: fixture.request,
                    handoffJSON: payload,
                    challenge: fixture.challenge
                )
                XCTFail("invalid handoff must fail before provider creation")
            } catch SessionHostAdapterV2Error.invalidHandoff {}
        }
        let stats = await transport.stats()
        XCTAssertEqual(stats.attempts, 0)
    }

    func testV2BlockedCredentialFailureAndLegacySyntheticQuarantinePersist() async throws {
        let blockedRoot = temporaryRoot("v2-auth")
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        let blockedTransport = ScriptedManagedTransport(
            mode: .unauthorized,
            ledgerURL: blockedRoot.appendingPathComponent("native-session-ledger.json")
        )
        let blocked = try makeV2Fixture(
            mission: "Exercise typed authorization failure.",
            idempotencyKey: "v2-auth"
        )
        let blockedAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: blockedRoot,
            transport: blockedTransport
        )
        for _ in 0..<2 {
            do {
                _ = try await blockedAdapter.createAndBootstrap(
                    request: blocked.request,
                    handoffJSON: blocked.handoffJSON,
                    challenge: blocked.challenge
                )
                XCTFail("credential failure must remain blocked")
            } catch LMStudioProviderError.unauthorized {}
        }
        let blockedStatus = await blockedAdapter.candidateStatus(
            forIdempotencyKey: blocked.request.idempotencyKey
        )
        XCTAssertEqual(blockedStatus, "blocked_failure")
        let blockedStats = await blockedTransport.stats()
        XCTAssertEqual(blockedStats.attempts, 1)

        let legacyRoot = temporaryRoot("v2-legacy")
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyLedgerURL = legacyRoot.appendingPathComponent("native-session-ledger.json")
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "records": [[
                "sessionID": "forge-logical-session-private",
                "providerSessionID": "native-fabricated-private",
                "idempotencyKey": "legacy-private-key",
            ]],
        ], options: [.sortedKeys])
        try legacyData.write(to: legacyLedgerURL, options: .atomic)
        let legacyTransport = ScriptedManagedTransport(
            mode: .normal,
            ledgerURL: legacyLedgerURL
        )
        let migrated = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: legacyRoot,
            transport: legacyTransport
        )
        let legacyCount = await migrated.legacyQuarantineCount()
        XCTAssertEqual(legacyCount, 1)
        let migratedText = try String(contentsOf: legacyLedgerURL, encoding: .utf8)
        XCTAssertTrue(migratedText.contains("legacy_v1_untrusted_provider_identity"))
        XCTAssertFalse(migratedText.contains("forge-logical-session-private"))
        XCTAssertFalse(migratedText.contains("native-fabricated-private"))
        XCTAssertFalse(migratedText.contains("legacy-private-key"))
    }

    func testLiveLMStudioFreshRootAcknowledgementAndAutomaticContinuation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelKey = environment["FORGE_LIVE_LMSTUDIO_MODEL"], !modelKey.isEmpty else {
            throw XCTSkip("Set FORGE_LIVE_LMSTUDIO_MODEL to run the real-provider system test")
        }
        let baseURLString = environment["FORGE_LIVE_LMSTUDIO_BASE_URL"]
            ?? "http://127.0.0.1:1234"
        let baseURL = try XCTUnwrap(URL(string: baseURLString))
        let configuration = LMStudioProviderConfiguration(
            baseURL: baseURL,
            modelKey: modelKey,
            connectTimeoutSeconds: 5,
            firstByteTimeoutSeconds: 90,
            idleTimeoutSeconds: 180,
            totalTimeoutSeconds: 300
        )
        let transport = try LMStudioManagedSessionTransport(configuration: configuration)
        let capabilities = try await transport.probe()
        XCTAssertEqual(capabilities.modelKey, modelKey)
        XCTAssertTrue(capabilities.functionToolContractVerified)
        XCTAssertTrue(capabilities.streamingVerified)
        XCTAssertTrue(capabilities.usageReportingVerified)
        XCTAssertTrue(capabilities.contractProbeResponseID?.hasPrefix("resp_") == true)

        let root = temporaryRoot("live-managed-continuity")
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let used = max(0, capabilities.contextLength - 5_120)
        let fixture = try makeV2Fixture(
            mission: "Acknowledge this exact durable handoff, then continue its first open action.",
            idempotencyKey: "live-managed-continuity-\(UUID().uuidString.lowercased())",
            modelKey: modelKey,
            contextCapacity: capabilities.contextLength,
            contextUsed: used
        )
        let receipt = try await adapter.createAndBootstrap(
            request: fixture.request,
            handoffJSON: fixture.handoffJSON,
            challenge: fixture.challenge
        )
        XCTAssertTrue(receipt.providerResponseID.hasPrefix("resp_"))
        XCTAssertFalse(receipt.providerResponseID.hasPrefix("native-"))
        XCTAssertNotEqual(receipt.providerResponseID, fixture.request.predecessorSessionID)
        XCTAssertEqual(receipt.acknowledgement.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.acknowledgement.projectID, fixture.request.projectID)
        XCTAssertEqual(
            receipt.acknowledgement.projectGeneration,
            fixture.request.projectGeneration
        )
        XCTAssertEqual(receipt.acknowledgement.runID, fixture.request.runID)
        XCTAssertEqual(receipt.acknowledgement.handoffID, fixture.handoffID)
        XCTAssertEqual(receipt.acknowledgement.handoffSHA256, fixture.handoffSHA256)
        XCTAssertEqual(receipt.acknowledgement.nonce, fixture.challenge.nonce)
        XCTAssertTrue(receipt.acknowledgement.accepted)
        XCTAssertGreaterThan(receipt.usage?.used ?? 0, 0)

        let provider = LMStudioManagedModelProvider(transport: transport)
        let continuationKey = "live-automatic-continuation-\(UUID().uuidString.lowercased())"
        let continuation = try await provider.continueSession(
            ProviderContinuationRequest(
                operationID: fixture.request.operationID,
                idempotencyKey: continuationKey,
                modelKey: modelKey,
                previousResponseID: receipt.providerResponseID,
                input: try ManagedContinuityWorker.automaticContinuationInput(),
                tools: []
            )
        )
        XCTAssertTrue(continuation.completed)
        XCTAssertTrue(continuation.responseID.hasPrefix("resp_"))
        XCTAssertFalse(continuation.responseID.hasPrefix("native-"))
        XCTAssertEqual(continuation.previousResponseID, receipt.providerResponseID)
        XCTAssertGreaterThan(continuation.usage?.inputTokens ?? 0, 0)
        XCTAssertGreaterThan(continuation.usage?.totalTokens ?? 0, 0)
        let reconciled = try await provider.lookup(idempotencyKey: continuationKey)
        XCTAssertEqual(reconciled, continuation)

        if let evidencePath = environment["FORGE_LIVE_LMSTUDIO_EVIDENCE"],
           !evidencePath.isEmpty {
            let evidence: [String: Any] = [
                "schema_version": 1,
                "provider": "lmstudio",
                "provider_version": capabilities.providerVersion,
                "model_key": capabilities.modelKey,
                "loaded_instance_id": capabilities.loadedInstanceID,
                "context_length": capabilities.contextLength,
                "capability_fingerprint_sha256": capabilities.capabilityFingerprintSHA256,
                "contract_probe_response_id": capabilities.contractProbeResponseID ?? NSNull(),
                "bootstrap_response_id": receipt.providerResponseID,
                "bootstrap_usage": receipt.usage?.asDictionary() ?? [:],
                "automatic_continuation_response_id": continuation.responseID,
                "automatic_continuation_previous_response_id": continuation.previousResponseID
                    ?? NSNull(),
                "automatic_continuation_usage": [
                    "capacity": continuation.usage?.capacity ?? 0,
                    "input_tokens": continuation.usage?.inputTokens ?? 0,
                    "output_tokens": continuation.usage?.outputTokens ?? 0,
                    "total_tokens": continuation.usage?.totalTokens ?? 0,
                    "source": continuation.usage?.source.rawValue ?? "unreported",
                ],
                "operation_id": fixture.request.operationID.uuidString.lowercased(),
                "handoff_id": fixture.handoffID.uuidString.lowercased(),
                "handoff_sha256": fixture.handoffSHA256,
                "acknowledgement_validated": true,
                "fresh_root_validated": true,
                "automatic_continuation_validated": true,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: evidence,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            let url = URL(fileURLWithPath: evidencePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
#endif

    func testFullAutonomousRolloverPersistsOnlyCompactIdentifiers() async throws {
        let fixture = try makeProjectFixture("autonomous")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let pluginDirectory = fixture.home.appendingPathComponent("NativeHost", isDirectory: true)
        let transport = LocalLogicalSessionTransport()
        let adapter = try ForgeNativeSessionHostAdapter(
            storageDirectory: pluginDirectory, transport: transport
        )
        let handoff = try makeHandoff(
            projectID: fixture.projectID,
            operationID: UUID().uuidString.lowercased(),
            mission: "Continue repair with api_key=private-fixture-value" // Example credential fixture.
        )
        let coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: fixture.memory))
        let completed = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "native-predecessor",
            adapter: adapter, idempotencyKey: "native-autonomous-rollover"
        )
        XCTAssertEqual(completed.state, .predecessorSealed)
        XCTAssertEqual(completed.acknowledgedHandoffID, handoff.handoffID)
        XCTAssertEqual(completed.acknowledgedSessionID, completed.successorSessionID)

        let ledgerURL = pluginDirectory.appendingPathComponent("native-session-ledger.json")
        let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledgerText.contains("private-fixture-value"))
        XCTAssertFalse(ledgerText.contains(handoff.mission))
        XCTAssertLessThan(ledgerText.utf8.count, 16 * 1024)

        let restarted = try ForgeNativeSessionHostAdapter(
            storageDirectory: pluginDirectory, transport: transport
        )
        let restored = try await restarted.session(forIdempotencyKey: "native-autonomous-rollover")
        XCTAssertEqual(restored?.id, completed.successorSessionID)
        let replay = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "native-predecessor",
            adapter: restarted, idempotencyKey: "native-autonomous-rollover"
        )
        XCTAssertEqual(replay, completed)
    }

    func testRateLimitRetryIdempotencyAndConcurrentProjects() async throws {
        let root = temporaryRoot("rate-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedNativeTransport(mode: .rateLimit(2))
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
        let firstRequest = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "predecessor-a", idempotencyKey: "project-a"
        )
        let first = try await adapter.createSession(firstRequest)
        let replay = try await adapter.createSession(firstRequest)
        XCTAssertEqual(first, replay)

        let secondRequest = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "predecessor-b", idempotencyKey: "project-b"
        )
        async let left = adapter.createSession(firstRequest)
        async let right = adapter.createSession(secondRequest)
        let concurrent = try await [left, right]
        XCTAssertNotEqual(concurrent[0].id, concurrent[1].id)
        let stats = await transport.stats()
        XCTAssertEqual(stats.attempts, 4)
        XCTAssertEqual(stats.effects, 2)
    }

    func testCancellationDeadlineMalformedAndStreamingBounds() async throws {
        let cases: [(String, ScriptedNativeTransport.Mode)] = [
            ("deadline", .deadline),
            ("malformed", .malformedAcknowledgement),
            ("oversized", .oversizedChunk),
        ]
        for (label, mode) in cases {
            let root = temporaryRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = ScriptedNativeTransport(mode: mode)
            let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
            let operationID = UUID().uuidString.lowercased()
            let request = SessionCreationRequest(
                operationID: operationID, projectID: UUID().uuidString.lowercased(),
                predecessorSessionID: "predecessor", idempotencyKey: label
            )
            if case .deadline = mode {
                do {
                    _ = try await adapter.createSession(request)
                    XCTFail("deadline must fail")
                } catch NativeHostPluginError.deadlineExceeded {}
                continue
            }
            let session = try await adapter.createSession(request)
            let handoff = try makeHandoff(
                projectID: request.projectID, operationID: operationID, mission: "Bound transport response"
            )
            do {
                try await adapter.bootstrap(session, handoff: handoff)
                XCTFail("\(label) response must fail")
            } catch NativeHostPluginError.malformedResponse {}
        }

        let cancelRoot = temporaryRoot("cancel")
        defer { try? FileManager.default.removeItem(at: cancelRoot) }
        let cancelTransport = ScriptedNativeTransport(mode: .normal)
        let cancelledAdapter = try ForgeNativeSessionHostAdapter(
            storageDirectory: cancelRoot, transport: cancelTransport
        )
        let cancelledOperation = UUID().uuidString.lowercased()
        await cancelledAdapter.cancel(operationID: cancelledOperation)
        do {
            _ = try await cancelledAdapter.createSession(SessionCreationRequest(
                operationID: cancelledOperation, projectID: UUID().uuidString.lowercased(),
                predecessorSessionID: "predecessor", idempotencyKey: "cancelled"
            ))
            XCTFail("cancelled operation must not create")
        } catch NativeHostPluginError.cancelled {}
        let cancellationStats = await cancelTransport.stats()
        XCTAssertEqual(cancellationStats.cancellations, 1)
    }

#if SWIFT_PACKAGE
    private struct V2Fixture {
        var request: SessionCreationRequestV2
        var challenge: BootstrapChallenge
        var handoffJSON: Data
        var handoffID: UUID
        var handoffSHA256: String
    }

    private func makeV2Fixture(
        mission: String,
        idempotencyKey: String,
        operationID: UUID = UUID(),
        modelKey: String = "fixture/tool-model",
        contextCapacity: Int = 32_768,
        contextUsed: Int = 28_000
    ) throws -> V2Fixture {
        let projectID = ProjectID()
        let generation = ProjectGeneration.initial
        let runID = RunID()
        let handoffID = UUID()
        let challenge = BootstrapChallenge(
            nonce: "fixture-nonce-" + String(repeating: "n", count: 48),
            acknowledgementContractVersion: 2
        )
        let request = SessionCreationRequestV2(
            operationID: operationID,
            projectID: projectID,
            projectGeneration: generation,
            runID: runID,
            predecessorSessionID: "resp_lms_predecessor",
            modelKey: modelKey,
            idempotencyKey: idempotencyKey
        )
        let reserved = min(1_024, max(0, contextCapacity - 1))
        let boundedUsed = min(max(0, contextUsed), max(0, contextCapacity - reserved))
        var object: [String: Any] = [
            "schema_version": "2.0",
            "handoff_id": handoffID.uuidString.lowercased(),
            "operation_id": operationID.uuidString.lowercased(),
            "created_at": "2026-08-26T12:00:00Z",
            "project": [
                "project_id": projectID.description,
                "generation": Int(generation.rawValue),
                "display_name": "V2 Fixture",
                "repository_root": "/fixture/project",
                "branch": "fixture/continuity",
                "commit": "0123456789abcdef",
                "dirty_summary": [] as [String],
            ] as [String: Any],
            "run": [
                "run_id": runID.description,
                "continuity_mode": "managedAutonomous",
                "assignment_id": NSNull(),
            ] as [String: Any],
            "predecessor_session": [
                "session_id": request.predecessorSessionID,
                "provider_id": "lmstudio",
                "provider_response_id": "resp_lms_predecessor",
                "adapter_id": ForgeNativeSessionHostPlugin.identifier,
                "model": request.modelKey,
            ] as [String: Any],
            "mission": mission,
            "constraints": [] as [String],
            "current_work": [
                "phase_id": "P09",
                "work_item_id": "FC-HOST-001",
                "summary": "Validate atomic create and bootstrap.",
                "active_files": [] as [String],
            ] as [String: Any],
            "completed_work": [] as [[String: Any]],
            "open_work": [] as [[String: Any]],
            "decisions": [] as [[String: Any]],
            "validation": [
                "passed_gates": [] as [String],
                "open_gates": [] as [String],
                "commands": [] as [[String: Any]],
            ] as [String: Any],
            "memory_references": [] as [[String: Any]],
            "evidence_references": [] as [[String: Any]],
            "next_actions": [[
                "order": 1,
                "action": "Continue automatically",
                "command": "",
                "success_condition": "Exact bootstrap acknowledgement is accepted",
            ]],
            "context_budget": [
                "capacity": contextCapacity,
                "used": boundedUsed,
                "reserved": reserved,
                "remaining": max(0, contextCapacity - boundedUsed - reserved),
                "source": "provider_exact",
                "confidence": 1.0,
                "action": "rollover",
                "trigger": "fixture threshold",
            ] as [String: Any],
            "bootstrap": [
                "nonce": challenge.nonce,
                "acknowledgement_contract_version": 2,
            ] as [String: Any],
        ]
        let checksum = try ContinuityHandoffV2Validation.contentSHA256(
            forJSONObject: object
        )
        object["integrity"] = [
            "canonicalization_version": ContinuityHandoffV2Validation.canonicalizationVersion,
            "content_sha256": checksum,
            "redaction_complete": true,
        ] as [String: Any]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return V2Fixture(
            request: request,
            challenge: challenge,
            handoffJSON: data,
            handoffID: handoffID,
            handoffSHA256: checksum
        )
    }

    private func mutateV2Handoff(
        _ data: Data,
        recomputeChecksum: Bool = true,
        mutation: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        mutation(&object)
        if recomputeChecksum {
            var integrity = try XCTUnwrap(object["integrity"] as? [String: Any])
            integrity["content_sha256"] = try ContinuityHandoffV2Validation.contentSHA256(
                forJSONObject: object
            )
            object["integrity"] = integrity
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func makeV2Transport() throws -> LMStudioManagedSessionTransport {
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!,
            modelKey: "fixture/tool-model",
            connectTimeoutSeconds: 1,
            firstByteTimeoutSeconds: 1,
            idleTimeoutSeconds: 1,
            totalTimeoutSeconds: 2
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LMStudioContractFixtureServer.self]
        return try LMStudioManagedSessionTransport(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )
    }
#endif

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-native-host-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeProjectFixture(_ label: String) throws -> (
        root: URL, home: URL, projectID: String, memory: ProjectMemoryService
    ) {
        let root = temporaryRoot(label)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let memory = ProjectMemoryService(paths: paths)
        let initialized = try memory.initialize(path: project.path)
        return (root, home, try XCTUnwrap(initialized["project_id"] as? String), memory)
    }

    private func makeHandoff(
        projectID: String, operationID: String, mission: String
    ) throws -> ContinuityHandoff {
        try ContinuityHandoff(
            operationID: operationID,
            project: [
                "project_id": projectID, "display_name": "Native Fixture", "repository_root": "/fixture",
                "branch": "repair/runtime", "commit": "1234567", "dirty_summary": [] as [String],
            ],
            predecessorSession: [
                "session_id": "native-predecessor", "provider_session_id": NSNull(), "model": NSNull(),
            ],
            mission: mission,
            currentWork: [
                "phase_id": "P09", "work_item_id": "P09-03", "summary": "Run native rollover",
                "active_files": [] as [String],
            ],
            nextActions: [[
                "order": 1, "action": "Continue automatically", "command": "",
                "success_condition": "Successor acknowledges the exact handoff",
            ]],
            hostState: [
                "adapter_id": ForgeNativeSessionHostPlugin.identifier,
                "continuity_state": ContinuityState.checkpointPreparing.rawValue,
                "context_budget_source": "provider_exact", "retry": [:] as [String: Any],
            ]
        ).validated()
    }
}

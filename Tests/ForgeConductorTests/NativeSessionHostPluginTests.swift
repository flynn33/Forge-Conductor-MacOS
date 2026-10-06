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

/// Delays one caller's actual transport error so both V2 persistence orders are
/// exercised. The fallback is finite and no response or error is fabricated.
private actor OrderedCancellationTransport: LMStudioManagedTransporting {
    private let underlying: LMStudioManagedSessionTransport
    private let delayedCaller: Int
    private var callerCount = 0
    private var delivery: Task<Void, Never>?
    private(set) var errorCount = 0

    init(_ underlying: LMStudioManagedSessionTransport, ownerReceivesErrorFirst: Bool) {
        self.underlying = underlying
        self.delayedCaller = ownerReceivesErrorFirst ? 1 : 0
    }
    var holdsError: Bool { delivery != nil }
    func releaseError() { delivery?.cancel() }
    func probe() async throws -> LMStudioProviderCapabilities { try await underlying.probe() }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        let caller = callerCount
        callerCount += 1
        do {
            return try await underlying.createRoot(request)
        } catch {
            errorCount += 1
            if caller == delayedCaller {
                let delivery = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(2)) }
                self.delivery = delivery
                defer { self.delivery = nil }
                await delivery.value
            }
            throw error
        }
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        try await underlying.continueSession(request)
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        await underlying.receipt(forIdempotencyKey: key)
    }
    func cancel(operationID: String) async { await underlying.cancel(operationID: operationID) }
}

/// Holds an actual parsed fixture response at the return boundary, with a finite
/// fallback, to exercise cancellation after the provider has already completed.
private actor CompletedResponseTransport: LMStudioManagedTransporting {
    private let underlying: LMStudioManagedSessionTransport
    private var delivery: Task<Void, Never>?

    init(_ underlying: LMStudioManagedSessionTransport) { self.underlying = underlying }
    var holdsCompletedResponse: Bool { delivery != nil }
    func releaseCompletedResponse() { delivery?.cancel() }
    func probe() async throws -> LMStudioProviderCapabilities { try await underlying.probe() }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        let turn = try await underlying.createRoot(request)
        let delivery = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(2)) }
        self.delivery = delivery
        defer { self.delivery = nil }
        await delivery.value
        return turn
    }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        try await underlying.continueSession(request)
    }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        await underlying.receipt(forIdempotencyKey: key)
    }
    func cancel(operationID: String) async { await underlying.cancel(operationID: operationID) }
}

private actor ScriptedManagedTransport: LMStudioManagedTransporting {
    enum Mode: Sendable {
        case normal
        case ambiguousFirstResponse
        case unauthorized
        case duplicateExactAcknowledgement
        case duplicateMismatchedAcknowledgement
    }

    private let mode: Mode
    private let ledgerURL: URL
    private let responseModel: String?
    private var attempts = 0
    private var receipts: [String: LMStudioResponseTurn] = [:]
    private var sawPersistedIntent = false
    private var bootstrapSystemPrompt: String?

    init(mode: Mode, ledgerURL: URL, responseModel: String? = nil) {
        self.mode = mode
        self.ledgerURL = ledgerURL
        self.responseModel = responseModel
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
        bootstrapSystemPrompt = request.systemPrompt
        if let ledgerText = try? String(contentsOf: ledgerURL, encoding: .utf8),
           ledgerText.contains("\"status\":\"intent\""),
           !ledgerText.contains(request.idempotencyKey) {
            sawPersistedIntent = true
        }
        if case .unauthorized = mode { throw LMStudioProviderError.unauthorized }
        var turn = try Self.turn(for: request, responseModel: responseModel)
        switch mode {
        case .duplicateExactAcknowledgement:
            guard let first = turn.functionCalls.first else { break }
            turn.functionCalls.append(LMStudioFunctionCall(
                itemID: first.itemID + "-duplicate",
                callID: first.callID + "-duplicate",
                name: first.name,
                arguments: first.arguments
            ))
        case .duplicateMismatchedAcknowledgement:
            guard let first = turn.functionCalls.first,
                  var object = try JSONSerialization.jsonObject(with: Data(first.arguments.utf8))
                    as? [String: Any] else { break }
            object["accepted"] = false
            turn.functionCalls.append(LMStudioFunctionCall(
                itemID: first.itemID + "-mismatch",
                callID: first.callID + "-mismatch",
                name: first.name,
                arguments: try JSONSupport.canonicalJSON(object)
            ))
        default:
            break
        }
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

    func stats() -> (
        attempts: Int, sawPersistedIntent: Bool, bootstrapSystemPrompt: String?
    ) {
        (attempts, sawPersistedIntent, bootstrapSystemPrompt)
    }

    private static func turn(
        for request: LMStudioRootRequest,
        responseModel: String?
    ) throws -> LMStudioResponseTurn {
        guard let data = request.userInput.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handoff = (root["handoff"] as? [String: Any]) ?? root as [String: Any]?,
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
            model: responseModel ?? request.modelKey ?? "fixture/tool-model",
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

// This protocol fixture gates a response before it exists. cancel() records the
// request but permits one deliberately late valid response to reach the adapter.
private enum NativeACKGateOutcome: Sendable, Equatable {
    case acknowledged
    case cancelled
    case failed(String)

    static func failure(_ error: any Error) -> Self {
        if let native = error as? NativeHostPluginError, native == .cancelled {
            return .cancelled
        }
        return .failed(String(String(describing: error).prefix(256)))
    }
}

private struct NativeACKGateSnapshot: Sendable {
    let enteredDigests: [String]
    let completedDigests: [String]
    let finishedDigests: [String]
    let cancelledOperations: [String]
}

private actor NativeACKRevisionGateTransport: NativeSessionTransport {
    nonisolated let bootstrapTimeout = Duration.seconds(4)
    private var entered: Set<String> = []
    private var released: Set<String> = []
    private var completed: [String] = []
    private var finished: Set<String> = []
    private var cancellations: Set<String> = []
    private var closed = false
    private var createKey: String?

    func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession {
        guard ContinuousClock.now < deadline else { throw NativeHostPluginError.deadlineExceeded }
        guard createKey == nil || createKey == request.idempotencyKey else {
            throw NativeHostPluginError.malformedResponse("gate fixture permits one native session")
        }
        createKey = request.idempotencyKey
        return NativeTransportSession(providerSessionID: "ack-gate-provider", model: "fixture-model")
    }

    func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse {
        guard !closed else { throw NativeHostPluginError.cancelled }
        guard entered.count < 2, !entered.contains(request.handoffSHA256) else {
            throw NativeHostPluginError.malformedResponse("duplicate or excess gate bootstrap")
        }
        let object = try JSONSerialization.jsonObject(with: request.canonicalHandoff)
        guard let dictionary = object as? [String: Any],
              let encoded = ContinuityHandoff.fromDictionary(dictionary) else {
            throw NativeHostPluginError.malformedResponse("gate received malformed canonical handoff")
        }
        let validated = try encoded.validated()
        guard validated.handoffID == request.handoffID,
              validated.contentSHA256 == request.handoffSHA256 else {
            throw NativeHostPluginError.malformedResponse("gate handoff identity or digest differs")
        }
        entered.insert(request.handoffSHA256)
        let localDeadline = ContinuousClock.now.advanced(by: bootstrapTimeout)
        for _ in 0..<800 {
            guard !closed else { throw NativeHostPluginError.cancelled }
            guard ContinuousClock.now < request.deadline,
                  ContinuousClock.now < localDeadline else {
                throw NativeHostPluginError.deadlineExceeded
            }
            if released.contains(request.handoffSHA256) {
                // Only this branch creates/completes an ACK. Waiting and cancel()
                // cannot manufacture a completed provider response.
                completed.append(request.handoffSHA256)
                return NativeBootstrapResponse(chunks: [try JSONSupport.data(from: [
                    "handoff_id": request.handoffID,
                    "successor_session_id": request.successorSessionID,
                ])], inputTokens: 100, outputTokens: 8)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeHostPluginError.deadlineExceeded
    }

    func cancel(operationID: String, providerSessionID: String?) async {
        // Deliberately keep an already-started transport return independently
        // controllable; NativeSessionTransport does not promise a join here.
        if cancellations.count < 2 { cancellations.insert(operationID) }
    }

    func release(_ digest: String) { if entered.contains(digest) { released.insert(digest) } }
    func taskFinished(_ digest: String) { if finished.count < 2 { finished.insert(digest) } }
    func close() { closed = true }

    func snapshot() -> NativeACKGateSnapshot {
        NativeACKGateSnapshot(enteredDigests: entered.sorted(), completedDigests: completed,
            finishedDigests: finished.sorted(), cancelledOperations: cancellations.sorted())
    }

    func waitForEntry(_ digest: String) async throws {
        for _ in 0..<200 {
            if entered.contains(digest) { return }
            guard !closed else { throw NativeHostPluginError.cancelled }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeHostPluginError.deadlineExceeded
    }

    func allowSecondAttemptToReachGateOrFinish(_ digest: String) async throws {
        // A future repair may reject or serialize B before transport. This
        // bounded coordination delay does not require the buggy second entry.
        for _ in 0..<200 {
            if entered.contains(digest) || finished.contains(digest) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class NativeSessionHostPluginTests: XCTestCase {
    func testSourceOnlyCancellationCannotOverwriteAnotherAdaptersNewLegacyReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-cancel-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appendingPathComponent("native-session-ledger.json")
        let stale = try LMStudioManagedSessionHostAdapterV2(storageDirectory: directory,
            transport: ScriptedManagedTransport(mode: .normal, ledgerURL: ledger))
        let writer = try LMStudioManagedSessionHostAdapterV2(storageDirectory: directory,
            transport: ScriptedManagedTransport(mode: .normal, ledgerURL: ledger))
        let fixture = try makeV2Fixture(mission: "Preserve the other adapter's committed receipt",
            idempotencyKey: "source-cancel-preserved-legacy")
        let receipt = try await writer.createAndBootstrap(request: fixture.request,
            handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        let committed = try Data(contentsOf: ledger)
        // Source cancellation can arrive before its in-flight entry is installed.
        // The older adapter has no matching legacy operation to mutate.
        await stale.cancel(operationID: UUID())
        XCTAssertEqual(try Data(contentsOf: ledger), committed)
        let reopened = try LMStudioManagedSessionHostAdapterV2(storageDirectory: directory,
            transport: ScriptedManagedTransport(mode: .normal, ledgerURL: ledger))
        let restored = try await reopened.receipt(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertEqual(restored, receipt)
    }

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

    func testConfiguredProductionRegistrationCreatesIdempotentGUISessionWithoutRESTDispatch() async throws {
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
        let request = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(),
            projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "provider-predecessor",
            idempotencyKey: "configured-production"
        )
        let created = try await adapter.createSession(request)
        let replayed = try await adapter.createSession(request)
        XCTAssertEqual(replayed, created)
        XCTAssertTrue(created.providerSessionID?.hasPrefix("lmstudio-gui-") == true)
        XCTAssertNil(created.model)
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

    func testProviderConfigurationDefaultsAndBoundsOutputTokens() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "base_url": "https://lmstudio.fixture",
            "model_key": "fixture/tool-model",
        ], options: [.sortedKeys])
        let configuration = try JSONDecoder().decode(
            LMStudioProviderConfiguration.self,
            from: data
        )
        XCTAssertEqual(configuration.maximumOutputTokens, 4_096)
        XCTAssertNoThrow(try configuration.validated())

        var boundary = configuration
        boundary.maximumOutputTokens = 1
        XCTAssertNoThrow(try boundary.validated())
        boundary.maximumOutputTokens = 4_096
        XCTAssertNoThrow(try boundary.validated())
        boundary.maximumOutputTokens = 4_097
        XCTAssertNoThrow(try boundary.validated())
        boundary.maximumOutputTokens = 8_192
        XCTAssertNoThrow(try boundary.validated())
        boundary.maximumOutputTokens = 65_536
        XCTAssertNoThrow(try boundary.validated())
        boundary.maximumOutputTokens = 0
        XCTAssertThrowsError(try boundary.validated())
        boundary.maximumOutputTokens = 65_537
        XCTAssertThrowsError(try boundary.validated())
        boundary.maximumOutputTokens = Int.max
        XCTAssertThrowsError(try boundary.validated())

        let encoded = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["maximum_output_tokens"] as? Int, 4_096)
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

    func testDefaultAuthorizationNeverReadsLegacyCredentialForLocalEndpoint() async throws {
        let local = LMStudioProviderConfiguration(
            endpointMode: .local,
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            modelKey: "fixture/tool-model",
            keychainTokenReference: "obsolete-local-reference"
        )
        let authorization = try ForgeNativeSessionHostPlugin.defaultAuthorization(for: local)
        let token = try await authorization.bearerToken()
        XCTAssertNil(token)
    }

    func testCancellingBootstrapOwnerStopsTransportAndPreservesRestartRecovery() async throws {
        let root = temporaryRoot("v2-owner-cancel")
        defer {
            LMStudioContractFixtureServer.suspendBootstrapRequests(false)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = LMStudioProviderConfiguration(baseURL: URL(string: "https://lmstudio.fixture")!,
            modelKey: "fixture/tool-model", connectTimeoutSeconds: 5, firstByteTimeoutSeconds: 120,
            idleTimeoutSeconds: 600, totalTimeoutSeconds: 600)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [LMStudioContractFixtureServer.self]
        let transport = try LMStudioManagedSessionTransport(configuration: configuration, sessionConfiguration: session)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: transport)
        let fixture = try makeV2Fixture(mission: "fixture-suspend-bootstrap",
            idempotencyKey: "v2-cancel-owner")
        LMStudioContractFixtureServer.suspendBootstrapRequests(true)
        let owner = Task {
            try await adapter.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        }
        for _ in 0..<400 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1)
        owner.cancel()
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 0,
            "Cancelled continuity owner left its URLSession request alive")
        // Explicit cleanup keeps this reproducer bounded even before the fix.
        await transport.cancel(operationID: fixture.request.operationID.uuidString.lowercased())
        do { _ = try await owner.value; XCTFail("Cancelled bootstrap returned a receipt") }
        catch is CancellationError {}
        catch LMStudioProviderError.cancelled {}
        let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("native-session-ledger.json"))) as? [String: Any])
        let record = try XCTUnwrap((ledger["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["status"] as? String, "retryable_failure")
        XCTAssertEqual(record["error_code"] as? String, "owner_interrupted")
        XCTAssertNil(record["receipt"])
        LMStudioContractFixtureServer.suspendBootstrapRequests(false)
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: try makeV2Transport())
        let recovered = try await restarted.createAndBootstrap(request: fixture.request,
            handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        XCTAssertEqual(recovered.acknowledgement.operationID, fixture.request.operationID)
        XCTAssertEqual(recovered.acknowledgement.handoffSHA256, fixture.handoffSHA256)
        let replayed = try await restarted.createAndBootstrap(request: fixture.request,
            handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        XCTAssertEqual(replayed, recovered)
    }

    func testCancelledCoalescedWaiterCannotCancelTransportOwner() async throws {
        LMStudioContractFixtureServer.suspendBootstrapRequests(true)
        defer { LMStudioContractFixtureServer.suspendBootstrapRequests(false) }
        let transport = try makeV2Transport()
        let request = LMStudioRootRequest(operationID: "coalesced-owner", modelKey: "fixture/tool-model",
            systemPrompt: "Fixture", userInput: "fixture-suspend-bootstrap", tools: [],
            idempotencyKey: "coalesced-owner")
        let owner = Task { try await transport.createRoot(request) }
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1)
        let waiter = Task { try await transport.createRoot(request) }
        waiter.cancel()
        // Leave the real URLSession request held while the cancelled waiter runs.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1)
        LMStudioContractFixtureServer.resumeBootstrapRequests()
        let original = try await owner.value
        let shared = try await waiter.value
        XCTAssertEqual(shared, original)
        let retained = await transport.receipt(forIdempotencyKey: request.idempotencyKey)
        XCTAssertEqual(retained, original)
    }

    func testV2OwnerFirstSharedCancellationRemainsRetryableAfterCompactionAndRestart() async throws {
        try await verifyV2SharedCancellation(explicitOperationCancellation: false, ownerReceivesErrorFirst: true)
    }

    func testV2WaiterFirstSharedCancellationRemainsRetryableAfterCompactionAndRestart() async throws {
        try await verifyV2SharedCancellation(explicitOperationCancellation: false, ownerReceivesErrorFirst: false)
    }

    func testV2ExplicitCancellationWinsBothCoalescedCallersAfterCompactionAndRestart() async throws {
        try await verifyV2SharedCancellation(explicitOperationCancellation: true, ownerReceivesErrorFirst: true)
    }

    private func verifyV2SharedCancellation(explicitOperationCancellation: Bool, ownerReceivesErrorFirst: Bool) async throws {
        let root = temporaryRoot("v2-shared-cancel")
        defer {
            LMStudioContractFixtureServer.suspendBootstrapRequests(false)
            try? FileManager.default.removeItem(at: root)
        }
        let transport = OrderedCancellationTransport(try makeV2Transport(), ownerReceivesErrorFirst: ownerReceivesErrorFirst)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: transport)
        let fixture = try makeV2Fixture(mission: "fixture-suspend-bootstrap",
            idempotencyKey: "v2-shared-cancel")
        func persistedRecord() throws -> [String: Any] {
            let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: root.appendingPathComponent("native-session-ledger.json"))) as? [String: Any])
            return try XCTUnwrap((ledger["records"] as? [[String: Any]])?.first)
        }
        LMStudioContractFixtureServer.suspendBootstrapRequests(true)
        let owner = Task {
            try await adapter.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        }
        defer { owner.cancel() }
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1)
        let waiter = Task {
            try await adapter.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        }
        defer { waiter.cancel() }
        for _ in 0..<200 {
            if try persistedRecord()["attempt"] as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try persistedRecord()["attempt"] as? Int, 2,
            "Both V2 calls must reach their persisted intent before cancellation")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1,
            "Both calls must share one held provider request")
        if explicitOperationCancellation {
            await adapter.cancel(operationID: fixture.request.operationID)
        } else {
            owner.cancel()
        }
        for _ in 0..<200 {
            let bothObserved = await transport.errorCount == 2
            let holdsError = await transport.holdsError
            let status = await adapter.candidateStatus(forIdempotencyKey: fixture.request.idempotencyKey)
            if bothObserved, holdsError, status != "intent" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let errorCount = await transport.errorCount
        let holdsError = await transport.holdsError
        XCTAssertEqual(errorCount, 2, "Both callers must receive the real shared transport error")
        XCTAssertTrue(holdsError, "One error must remain held until the first caller publishes its outcome")
        let firstStatus = await adapter.candidateStatus(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertNotEqual(firstStatus, "intent", "The first caller must persist its result before the second error is delivered")
        await transport.releaseError()
        do { _ = try await owner.value; XCTFail("Cancelled shared request returned a receipt") }
        catch is CancellationError {}
        catch LMStudioProviderError.cancelled {}
        do { _ = try await waiter.value; XCTFail("Shared cancellation did not reach the second V2 caller") }
        catch is CancellationError {}
        catch LMStudioProviderError.cancelled {}
        XCTAssertFalse(waiter.isCancelled, "The second caller must observe shared cancellation without being cancelled itself")
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 0)
        let expectedStatus = explicitOperationCancellation ? "cancelled" : "retryable_failure"
        XCTAssertEqual(try persistedRecord()["status"] as? String, expectedStatus)
        XCTAssertNil(try persistedRecord()["receipt"])
        let compacted = try await adapter.compactTerminalLedger(retainingRecentTerminalRecords: 0)
        XCTAssertEqual(compacted, explicitOperationCancellation ? 1 : 0,
            "Owner interruption must remain recoverable rather than becoming terminal reconciliation")
        LMStudioContractFixtureServer.suspendBootstrapRequests(false)
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: try makeV2Transport())
        let restoredStatus = await restarted.candidateStatus(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertEqual(restoredStatus, expectedStatus)
        if explicitOperationCancellation {
            do {
                _ = try await restarted.createAndBootstrap(request: fixture.request,
                    handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
                XCTFail("Compacted explicit cancellation must not be replayed")
            } catch LMStudioProviderError.cancelled {}
        } else {
            let recovered = try await restarted.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
            XCTAssertEqual(recovered.acknowledgement.operationID, fixture.request.operationID)
            XCTAssertEqual(recovered.acknowledgement.handoffSHA256, fixture.handoffSHA256)
            let replayed = try await restarted.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
            XCTAssertEqual(replayed, recovered)
        }
    }

    func testCompletedBootstrapReceiptWinsOwnerCancellationAndSurvivesRestart() async throws {
        let root = temporaryRoot("v2-completed-owner-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CompletedResponseTransport(try makeV2Transport())
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: transport)
        let fixture = try makeV2Fixture(mission: "Complete before owner cancellation",
            idempotencyKey: "v2-completed-owner-cancel")
        let owner = Task {
            try await adapter.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        }
        for _ in 0..<200 {
            if await transport.holdsCompletedResponse { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let hasActualCompletedResponse = await transport.holdsCompletedResponse
        XCTAssertTrue(hasActualCompletedResponse)
        owner.cancel()
        await transport.releaseCompletedResponse()
        let accepted = try await owner.value
        XCTAssertEqual(accepted.acknowledgement.operationID, fixture.request.operationID)
        XCTAssertEqual(accepted.acknowledgement.handoffSHA256, fixture.handoffSHA256)
        await adapter.cancel(operationID: fixture.request.operationID)
        let status = await adapter.candidateStatus(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertEqual(status, "accepted")
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: try makeV2Transport())
        let retained = try await restarted.receipt(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertEqual(retained, accepted)
    }

    func testExplicitBootstrapCancellationRemainsDurablyCancelled() async throws {
        let root = temporaryRoot("v2-explicit-cancel")
        defer {
            LMStudioContractFixtureServer.suspendBootstrapRequests(false)
            try? FileManager.default.removeItem(at: root)
        }
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: try makeV2Transport())
        let fixture = try makeV2Fixture(mission: "fixture-suspend-bootstrap",
            idempotencyKey: "v2-explicit-cancel")
        LMStudioContractFixtureServer.suspendBootstrapRequests(true)
        let owner = Task {
            try await adapter.createAndBootstrap(request: fixture.request,
                handoffJSON: fixture.handoffJSON, challenge: fixture.challenge)
        }
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 1)
        await adapter.cancel(operationID: fixture.request.operationID)
        do { _ = try await owner.value; XCTFail("Explicit cancellation returned a receipt") }
        catch LMStudioProviderError.cancelled {}
        for _ in 0..<200 {
            if LMStudioContractFixtureServer.suspendedBootstrapCount == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(LMStudioContractFixtureServer.suspendedBootstrapCount, 0)
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: root, transport: try makeV2Transport())
        let status = await restarted.candidateStatus(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertEqual(status, "cancelled")
        let receipt = try await restarted.receipt(forIdempotencyKey: fixture.request.idempotencyKey)
        XCTAssertNil(receipt)
    }

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
                .map(\.lastPathComponent)
                .sorted(),
            [
                "native-session-ledger.json",
                "native-session-ledger.json.migration.lock",
            ]
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
        XCTAssertTrue(stats.bootstrapSystemPrompt?.contains(
            "only the fresh-root bootstrap response"
        ) == true)
        XCTAssertTrue(stats.bootstrapSystemPrompt?.contains(
            "In a later response rooted at this one"
        ) == true)
        let acceptedStatus = await restarted.candidateStatus(
            forIdempotencyKey: fixture.request.idempotencyKey
        )
        XCTAssertEqual(acceptedStatus, "accepted")
    }

    func testV2AcceptsExactProbedLoadedInstanceAliasAndPersistsCanonicalModelKey() async throws {
        let root = temporaryRoot("v2-loaded-instance-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = ScriptedManagedTransport(
            mode: .normal,
            ledgerURL: root.appendingPathComponent("native-session-ledger.json"),
            responseModel: "fixture/tool-model@32768"
        )
        let fixture = try makeV2Fixture(
            mission: "Bind the exact loaded instance without changing the model key.",
            idempotencyKey: "v2-loaded-instance-alias"
        )
        let adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let receipt = try await adapter.createAndBootstrap(
            request: fixture.request,
            handoffJSON: fixture.handoffJSON,
            challenge: fixture.challenge
        )
        XCTAssertEqual(receipt.modelKey, fixture.request.modelKey)
        XCTAssertTrue(receipt.acknowledgement.accepted)

        let reopened = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let replay = try await reopened.receipt(
            forIdempotencyKey: fixture.request.idempotencyKey
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(replay?.modelKey, fixture.request.modelKey)
    }

    func testV2CoalescesIdenticalAcknowledgementCallsAndRejectsDivergence() async throws {
        let acceptedRoot = temporaryRoot("v2-duplicate-exact-ack")
        defer { try? FileManager.default.removeItem(at: acceptedRoot) }
        let acceptedFixture = try makeV2Fixture(
            mission: "Coalesce identical acknowledgement declarations.",
            idempotencyKey: "v2-duplicate-exact-ack"
        )
        let acceptedAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: acceptedRoot,
            transport: ScriptedManagedTransport(
                mode: .duplicateExactAcknowledgement,
                ledgerURL: acceptedRoot.appendingPathComponent("native-session-ledger.json")
            )
        )
        let receipt = try await acceptedAdapter.createAndBootstrap(
            request: acceptedFixture.request,
            handoffJSON: acceptedFixture.handoffJSON,
            challenge: acceptedFixture.challenge
        )
        XCTAssertEqual(receipt.acknowledgement.operationID, acceptedFixture.request.operationID)
        let acceptedStatus = await acceptedAdapter.candidateStatus(
            forIdempotencyKey: acceptedFixture.request.idempotencyKey
        )
        XCTAssertEqual(acceptedStatus, "accepted")

        let rejectedRoot = temporaryRoot("v2-duplicate-divergent-ack")
        defer { try? FileManager.default.removeItem(at: rejectedRoot) }
        let rejectedFixture = try makeV2Fixture(
            mission: "Reject divergent acknowledgement declarations.",
            idempotencyKey: "v2-duplicate-divergent-ack"
        )
        let rejectedAdapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: rejectedRoot,
            transport: ScriptedManagedTransport(
                mode: .duplicateMismatchedAcknowledgement,
                ledgerURL: rejectedRoot.appendingPathComponent("native-session-ledger.json")
            )
        )
        do {
            _ = try await rejectedAdapter.createAndBootstrap(
                request: rejectedFixture.request,
                handoffJSON: rejectedFixture.handoffJSON,
                challenge: rejectedFixture.challenge
            )
            XCTFail("Divergent acknowledgement calls must be rejected")
        } catch SessionHostAdapterV2Error.acknowledgementMismatch { }
        let rejectedStatus = await rejectedAdapter.candidateStatus(
            forIdempotencyKey: rejectedFixture.request.idempotencyKey
        )
        XCTAssertEqual(rejectedStatus, "quarantined")
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
        let backupURL = legacyRoot.appendingPathComponent(
            "native-session-ledger.pre-migration-v1.json"
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), legacyData)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )
        let targetArtifactURL = legacyRoot.appendingPathComponent(
            "native-session-ledger.schema-v2.target.json"
        )
        let migrationManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: legacyLedgerURL)
            )
        )
        XCTAssertEqual(migrationManifest.state, .completed)
        XCTAssertEqual(migrationManifest.storageKind, .file)
        XCTAssertEqual(migrationManifest.sourceVersion, 1)
        XCTAssertEqual(migrationManifest.targetVersion, 2)
        XCTAssertEqual(migrationManifest.sourceSHA256, JSONSupport.sha256Hex(legacyData))
        XCTAssertEqual(
            migrationManifest.targetSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: targetArtifactURL))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: 2
                ).path
            )
        )
        let firstBackupData = try Data(contentsOf: backupURL)
        let legacyCount = await migrated.legacyQuarantineCount()
        XCTAssertEqual(legacyCount, 1)
        let firstMigrationData = try Data(contentsOf: legacyLedgerURL)
        let migratedText = try XCTUnwrap(String(data: firstMigrationData, encoding: .utf8))
        XCTAssertTrue(migratedText.contains("legacy_v1_untrusted_provider_identity"))
        XCTAssertFalse(migratedText.contains("forge-logical-session-private"))
        XCTAssertFalse(migratedText.contains("native-fabricated-private"))
        XCTAssertFalse(migratedText.contains("legacy-private-key"))
        let migratedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: firstMigrationData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schema_version"] as? Int, 2)
        XCTAssertEqual((migratedObject["records"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((migratedObject["legacy_quarantine"] as? [[String: Any]])?.count, 1)

        try legacyData.write(to: legacyLedgerURL, options: .atomic)
        let preparedBackup = try VerifiedMigrationBackup.copyFile(
            from: legacyLedgerURL,
            to: backupURL,
            maximumBytes: 2 * 1_024 * 1_024
        )
        let preparedTarget = try VerifiedMigrationBackup.writeFile(
            firstMigrationData,
            to: targetArtifactURL,
            maximumBytes: 2 * 1_024 * 1_024
        )
        let preparedRestart = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: legacyLedgerURL,
            backup: preparedBackup,
            sourceVersion: 1,
            targetVersion: 2,
            storageKind: .file,
            targetArtifact: preparedTarget
        )
        XCTAssertEqual(preparedRestart.state, .prepared)
        let resumedAfterPrepared = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: legacyRoot,
            transport: legacyTransport
        )
        let resumedLegacyCount = await resumedAfterPrepared.legacyQuarantineCount()
        XCTAssertEqual(resumedLegacyCount, 1)
        XCTAssertEqual(try Data(contentsOf: legacyLedgerURL), firstMigrationData)
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(
                    contentsOf: VerifiedMigrationBackup.activeManifestURL(for: legacyLedgerURL)
                )
            ).state,
            .completed
        )

        let reopenedTransport = ScriptedManagedTransport(
            mode: .normal,
            ledgerURL: legacyLedgerURL
        )
        let reopened = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: legacyRoot,
            transport: reopenedTransport
        )
        let reopenedLegacyCount = await reopened.legacyQuarantineCount()
        XCTAssertEqual(reopenedLegacyCount, 1)
        XCTAssertEqual(try Data(contentsOf: legacyLedgerURL), firstMigrationData)
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)

        let rerun = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: legacyRoot,
            transport: reopenedTransport
        )
        let rerunLegacyCount = await rerun.legacyQuarantineCount()
        XCTAssertEqual(rerunLegacyCount, 1)
        XCTAssertEqual(try Data(contentsOf: legacyLedgerURL), firstMigrationData)
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)
    }

    func testNativeLedgerChangedRestoreUsesBoundedImmutableLineages() async throws {
        let root = temporaryRoot("v2-ledger-lineages")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("native-session-ledger.json")
        let transport = ScriptedManagedTransport(mode: .normal, ledgerURL: ledgerURL)

        func legacyData(_ lineage: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "records": [[
                    "sessionID": "legacy-logical-\(lineage)",
                    "providerSessionID": "legacy-provider-\(lineage)",
                    "idempotencyKey": "legacy-idempotency-\(lineage)",
                ]],
            ], options: [.sortedKeys])
        }

        let firstSource = try legacyData(1)
        try firstSource.write(to: ledgerURL, options: .atomic)
        let first = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let firstQuarantineCount = await first.legacyQuarantineCount()
        XCTAssertEqual(firstQuarantineCount, 1)
        let firstBackupURL = root.appendingPathComponent(
            "native-session-ledger.pre-migration-v1.json"
        )
        let firstTargetURL = root.appendingPathComponent(
            "native-session-ledger.schema-v2.target.json"
        )
        let firstBackup = try Data(contentsOf: firstBackupURL)
        let firstTarget = try Data(contentsOf: firstTargetURL)
        let firstArchiveURL = VerifiedMigrationBackup.archivedManifestURL(
            for: firstBackupURL,
            targetVersion: 2
        )
        let firstArchive = try Data(contentsOf: firstArchiveURL)

        let secondSource = try legacyData(2)
        try secondSource.write(to: ledgerURL, options: .atomic)
        let second = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        let secondQuarantineCount = await second.legacyQuarantineCount()
        XCTAssertEqual(secondQuarantineCount, 1)
        let secondBackupURL = root.appendingPathComponent(
            "native-session-ledger.pre-migration-v1.lineage-2.json"
        )
        let secondTargetURL = root.appendingPathComponent(
            "native-session-ledger.schema-v2.target.lineage-2.json"
        )
        XCTAssertEqual(try Data(contentsOf: secondBackupURL), secondSource)
        XCTAssertEqual(try Data(contentsOf: firstBackupURL), firstBackup)
        XCTAssertEqual(try Data(contentsOf: firstTargetURL), firstTarget)
        XCTAssertEqual(try Data(contentsOf: firstArchiveURL), firstArchive)

        let secondManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: ledgerURL))
        )
        XCTAssertEqual(secondManifest.state, .completed)
        XCTAssertEqual(secondManifest.backupFilename, secondBackupURL.lastPathComponent)
        XCTAssertEqual(secondManifest.targetArtifactFilename, secondTargetURL.lastPathComponent)
        XCTAssertEqual(secondManifest.sourceSHA256, JSONSupport.sha256Hex(secondSource))
        XCTAssertEqual(
            secondManifest.targetSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: secondTargetURL))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: secondBackupURL,
                    targetVersion: 2
                ).path
            )
        )
        let secondInstalled = try Data(contentsOf: ledgerURL)
        _ = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: root,
            transport: transport
        )
        XCTAssertEqual(try Data(contentsOf: ledgerURL), secondInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "native-session-ledger.pre-migration-v1.lineage-3.json"
                ).path
            )
        )

        for lineage in 3...LMStudioManagedSessionHostAdapterV2.maximumMigrationLineages {
            try legacyData(lineage).write(to: ledgerURL, options: .atomic)
            _ = try LMStudioManagedSessionHostAdapterV2(
                storageDirectory: root,
                transport: transport
            )
        }
        let completedFourthManifest = try Data(
            contentsOf: VerifiedMigrationBackup.activeManifestURL(for: ledgerURL)
        )
        let fifthSource = try legacyData(
            LMStudioManagedSessionHostAdapterV2.maximumMigrationLineages + 1
        )
        try fifthSource.write(to: ledgerURL, options: .atomic)
        XCTAssertThrowsError(
            try LMStudioManagedSessionHostAdapterV2(
                storageDirectory: root,
                transport: transport
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "all bounded file migration lineages are occupied"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: ledgerURL), fifthSource)
        XCTAssertEqual(
            try Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: ledgerURL)),
            completedFourthManifest
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "native-session-ledger.pre-migration-v1.lineage-5.json"
                ).path
            )
        )
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
            totalTimeoutSeconds: 300,
            maximumOutputTokens: 4_096
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
            mission: "Acknowledge this exact durable handoff, then report the continuation marker.",
            idempotencyKey: "live-managed-continuity-\(UUID().uuidString.lowercased())",
            modelKey: modelKey,
            contextCapacity: capabilities.contextLength,
            contextUsed: used,
            nextAction: "Reply with FORGE_CONTINUATION_READY and no other final-answer text.",
            nextActionSuccessCondition: "The response contains FORGE_CONTINUATION_READY"
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
        XCTAssertLessThanOrEqual(continuation.usage?.outputTokens ?? .max, 4_096)
        XCTAssertTrue(continuation.messages.joined(separator: "\n").contains(
            "FORGE_CONTINUATION_READY"
        ))
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
                "automatic_continuation_marker_validated": true,
                "maximum_output_tokens": configuration.maximumOutputTokens,
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

    #if canImport(AppKit)
    func testInteractiveNativeAdapterRejectsForeignDeploymentReceiptBeforeGUIActions() async throws {
        let root = temporaryRoot("gui-foreign-deployment-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let acknowledgementDirectory = root.appendingPathComponent("acknowledgements", isDirectory: true)
        try FileManager.default.createDirectory(at: acknowledgementDirectory, withIntermediateDirectories: true)
        let transport = LMStudioInteractiveSessionTransport(
            guiDriver: LMStudioGUIChatDriver(), acknowledgementDirectory: acknowledgementDirectory
        )
        let storage = root.appendingPathComponent("native-host", isDirectory: true)
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: storage, transport: transport)
        let operationID = UUID().uuidString.lowercased()
        let projectID = UUID().uuidString.lowercased()
        let owner = "lm-studio:" + String(repeating: "5", count: 64)
        let foreign = "lm-studio:" + String(repeating: "6", count: 64)
        let session = try await adapter.createSession(SessionCreationRequest(
            operationID: operationID, projectID: projectID,
            predecessorSessionID: owner, idempotencyKey: "gui-foreign-receipt"
        ))
        var handoff = try makeHandoff(projectID: projectID, operationID: operationID, mission: "Validate deployment ownership")
        handoff.handoffID = operationID
        handoff.predecessorSession["session_id"] = owner
        handoff.project["repository_root"] = root.path
        handoff = try handoff.validated()
        let acknowledgementURL = acknowledgementDirectory.appendingPathComponent("\(handoff.handoffID.lowercased()).json")
        try OwnerOnlyAtomicFile.write(try JSONSupport.data(from: [
            "schema_version": 1, "handoff_id": handoff.handoffID,
            "rollover_nonce": LMStudioInteractiveSessionTransport.rolloverNonce(operationID: operationID),
            "tool": "get_forge_status", "resume": true, "client_id": foreign,
            "acknowledged_at": "2026-10-05T23:00:00Z",
        ]), to: acknowledgementURL)
        // Recover the retained ledger owner. This matching receipt is consumed
        // before the production driver can access LM Studio's AX surface.
        let restarted = try ForgeNativeSessionHostAdapter(storageDirectory: storage, transport: transport)
        do {
            try await restarted.bootstrap(session, handoff: handoff)
            XCTFail("A foreign deployment receipt must not acknowledge the native successor")
        } catch let error as NativeHostPluginError {
            guard case .malformedResponse(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "LM Studio GUI successor acknowledgement client identity differs")
        }
        do {
            _ = try await restarted.awaitAcknowledgement(session: session, handoffID: handoff.handoffID, timeout: .milliseconds(1))
            XCTFail("The foreign receipt must leave the successor unacknowledged")
        } catch NativeHostPluginError.deadlineExceeded {}
    }

    func testInteractiveNativeAdapterAcceptsMatchingScopedAndLegacyReceiptsAfterRestart() async throws {
        for owner in ["lm-studio:" + String(repeating: "7", count: 64), "lmstudio-predecessor"] {
            let root = temporaryRoot("gui-matching-deployment-receipt")
            defer { try? FileManager.default.removeItem(at: root) }
            let acknowledgementDirectory = root.appendingPathComponent("acknowledgements", isDirectory: true)
            try FileManager.default.createDirectory(at: acknowledgementDirectory, withIntermediateDirectories: true)
            let transport = LMStudioInteractiveSessionTransport(
                guiDriver: LMStudioGUIChatDriver(), acknowledgementDirectory: acknowledgementDirectory
            )
            let storage = root.appendingPathComponent("native-host", isDirectory: true)
            let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: storage, transport: transport)
            let operationID = UUID().uuidString.lowercased()
            let projectID = UUID().uuidString.lowercased()
            let session = try await adapter.createSession(SessionCreationRequest(
                operationID: operationID, projectID: projectID,
                predecessorSessionID: owner, idempotencyKey: "gui-matching-receipt"
            ))
            var handoff = try makeHandoff(projectID: projectID, operationID: operationID, mission: "Validate matching deployment")
            handoff.handoffID = operationID
            handoff.predecessorSession["session_id"] = owner
            handoff.project["repository_root"] = root.path
            handoff = try handoff.validated()
            let acknowledgementURL = acknowledgementDirectory.appendingPathComponent("\(handoff.handoffID.lowercased()).json")
            let receipt = try JSONSupport.data(from: [
                "schema_version": 1, "handoff_id": handoff.handoffID,
                "rollover_nonce": LMStudioInteractiveSessionTransport.rolloverNonce(operationID: operationID),
                "tool": "get_forge_status", "resume": true, "client_id": owner,
                "acknowledged_at": "2026-10-05T23:00:00Z",
            ])
            try OwnerOnlyAtomicFile.write(receipt, to: acknowledgementURL)
            let restarted = try ForgeNativeSessionHostAdapter(storageDirectory: storage, transport: transport)
            try await restarted.bootstrap(session, handoff: handoff)
            let recovered = try ForgeNativeSessionHostAdapter(storageDirectory: storage, transport: transport)
            let acknowledgement = try await recovered.awaitAcknowledgement(
                session: session, handoffID: handoff.handoffID, timeout: .milliseconds(1)
            )
            XCTAssertEqual(acknowledgement.handoffID, handoff.handoffID)
            XCTAssertEqual(acknowledgement.successorSessionID, session.id)
            XCTAssertEqual(acknowledgement.adapterID, ForgeNativeSessionHostPlugin.identifier)
            XCTAssertEqual(try OwnerOnlyAtomicFile.read(from: acknowledgementURL, maximumBytes: 8_192), receipt)
            let ledger = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: storage.appendingPathComponent("native-session-ledger.json"))
            ) as? [String: Any])
            XCTAssertEqual(ledger["schemaVersion"] as? Int, 1)
            let record = try XCTUnwrap((ledger["records"] as? [[String: Any]])?.first)
            XCTAssertEqual(record["predecessorSessionID"] as? String, owner)
            XCTAssertEqual(record["status"] as? String, "acknowledged")
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

    func testConcurrentNativeBootstrapCannotAcknowledgeUncompletedHandoffDigest() async throws {
        let root = temporaryRoot("v1-concurrent-ack-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NativeACKRevisionGateTransport()
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
        let request = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "ack-gate-predecessor", idempotencyKey: "v1-concurrent-ack-digest"
        )
        let session = try await adapter.createSession(request)
        let a = try makeHandoff(projectID: request.projectID, operationID: request.operationID,
            mission: "Load revision A before returning its acknowledgement")
        var secondHandoff = a
        secondHandoff.mission = "Revision B must not borrow A's completed acknowledgement"
        let b = try secondHandoff.validated()
        XCTAssertEqual(a.handoffID, b.handoffID)
        XCTAssertNotEqual(a.contentSHA256, b.contentSHA256)

        var tasks: [Task<NativeACKGateOutcome, Never>] = []
        let first = Task { () -> NativeACKGateOutcome in
            let outcome: NativeACKGateOutcome
            do { try await adapter.bootstrap(session, handoff: a); outcome = .acknowledged }
            catch { outcome = .failure(error) }
            await transport.taskFinished(a.contentSHA256)
            return outcome
        }
        tasks.append(first)
        do {
            try await transport.waitForEntry(a.contentSHA256)
            let beforeSecond = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(beforeSecond["status"] as? String, "bootstrapping")
            XCTAssertEqual(beforeSecond["handoffSHA256"] as? String, a.contentSHA256)
            let second = Task { () -> NativeACKGateOutcome in
                let outcome: NativeACKGateOutcome
                do { try await adapter.bootstrap(session, handoff: b); outcome = .acknowledged }
                catch { outcome = .failure(error) }
                await transport.taskFinished(b.contentSHA256)
                return outcome
            }
            tasks.append(second)
            try await transport.allowSecondAttemptToReachGateOrFinish(b.contentSHA256)
            let beforeResponse = await transport.snapshot()
            XCTAssertTrue(beforeResponse.enteredDigests.contains(a.contentSHA256))
            XCTAssertTrue(beforeResponse.completedDigests.isEmpty,
                "No ACK exists before release(A), including any rejected/serialized B attempt")
            await transport.release(a.contentSHA256)
            let firstOutcome = await first.value
            XCTAssertEqual(firstOutcome, .acknowledged)
            let completed = await transport.snapshot()
            XCTAssertEqual(completed.completedDigests, [a.contentSHA256],
                "Only revision A received a completed transport acknowledgement")

            let retained = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(retained["status"] as? String, "acknowledged")
            XCTAssertEqual(retained["handoffID"] as? String, a.handoffID)
            XCTAssertEqual(retained["handoffSHA256"] as? String, a.contentSHA256,
                "An ACK for A must not persist B's digest")
            XCTAssertNotEqual(retained["handoffSHA256"] as? String, b.contentSHA256)
            let acknowledgement = try await adapter.awaitAcknowledgement(
                session: session, handoffID: a.handoffID, timeout: .seconds(1))
            XCTAssertEqual(acknowledgement.handoffID, a.handoffID)
            XCTAssertEqual(acknowledgement.successorSessionID, session.id)

            // Same-content completed receipt replay must remain usable both in
            // the live adapter and after restart, without another transport ACK.
            do { try await adapter.bootstrap(session, handoff: a) }
            catch { XCTFail("Completed A receipt replay rejected: \(error)") }
            let restarted = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
            do { try await restarted.bootstrap(session, handoff: a) }
            catch { XCTFail("Restarted completed A receipt replay rejected: \(error)") }
            let restartedAck = try await restarted.awaitAcknowledgement(
                session: session, handoffID: a.handoffID, timeout: .seconds(1))
            XCTAssertEqual(restartedAck, acknowledgement)

            // B's in-flight task is still gated and no B response has completed.
            // A replay of B must never return a successful receipt using A's ACK.
            var replayAcceptedB = false
            do { try await adapter.bootstrap(session, handoff: b); replayAcceptedB = true }
            catch {}
            XCTAssertFalse(replayAcceptedB, "Uncompleted B borrowed the successful A receipt")
            let afterReplay = await transport.snapshot()
            XCTAssertEqual(afterReplay.completedDigests, [a.contentSHA256])
        } catch {
            await finishNativeACKGate(transport, tasks: tasks)
            throw error
        }
        await finishNativeACKGate(transport, tasks: tasks)
    }

    func testExplicitNativeBootstrapCancellationCannotBeResurrectedByLateACK() async throws {
        let root = temporaryRoot("v1-explicit-cancel-late-ack")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NativeACKRevisionGateTransport()
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
        let request = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "ack-gate-predecessor", idempotencyKey: "v1-explicit-cancel-late-ack"
        )
        let session = try await adapter.createSession(request)
        let handoff = try makeHandoff(projectID: request.projectID, operationID: request.operationID,
            mission: "Cancel before any native bootstrap response completes")
        let owner = Task { () -> NativeACKGateOutcome in
            do { try await adapter.bootstrap(session, handoff: handoff); return .acknowledged }
            catch { return .failure(error) }
        }
        do {
            try await transport.waitForEntry(handoff.contentSHA256)
            let beforeCancel = await transport.snapshot()
            XCTAssertTrue(beforeCancel.completedDigests.isEmpty,
                "This fixture has no completed response at cancellation")
            await adapter.cancel(operationID: request.operationID)
            let cancelled = await transport.snapshot()
            XCTAssertEqual(cancelled.cancelledOperations, [request.operationID])
            XCTAssertTrue(cancelled.completedDigests.isEmpty)
            let cancelledRow = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(cancelledRow["status"] as? String, "cancelled")

            // Explicit cancellation is already durable; now return the exact
            // otherwise-valid ACK to exercise the adapter's post-await fence.
            await transport.release(handoff.contentSHA256)
            let outcome = await owner.value
            XCTAssertEqual(outcome, .cancelled)
            let late = await transport.snapshot()
            XCTAssertEqual(late.completedDigests, [handoff.contentSHA256],
                "The cancelled adapter was offered an actual late identity-matching ACK")
            let retained = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(retained["status"] as? String, "cancelled")
            do {
                _ = try await adapter.awaitAcknowledgement(
                    session: session, handoffID: handoff.handoffID, timeout: .seconds(1))
                XCTFail("Explicitly cancelled operation returned a handoff acknowledgement")
            } catch NativeHostPluginError.deadlineExceeded {}
            let restarted = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
            let restoredSession = try await restarted.session(forIdempotencyKey: request.idempotencyKey)
            XCTAssertNil(restoredSession)
            do {
                _ = try await restarted.awaitAcknowledgement(
                    session: session, handoffID: handoff.handoffID, timeout: .seconds(1))
                XCTFail("Restart resurrected the explicitly cancelled receipt")
            } catch NativeHostPluginError.deadlineExceeded {}
        } catch {
            await finishNativeACKGate(transport, tasks: [owner])
            throw error
        }
        await finishNativeACKGate(transport, tasks: [owner])
    }

    func testInterruptedNativeBootstrapCanRetryItsDurableIntentAfterRestart() async throws {
        let root = temporaryRoot("v1-restart-pending-bootstrap")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NativeACKRevisionGateTransport()
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
        let request = SessionCreationRequest(operationID: UUID().uuidString.lowercased(),
            projectID: UUID().uuidString.lowercased(), predecessorSessionID: "ack-gate-predecessor",
            idempotencyKey: "v1-restart-pending-bootstrap")
        let session = try await adapter.createSession(request)
        let handoff = try makeHandoff(projectID: request.projectID, operationID: request.operationID,
            mission: "Retry the durable unacknowledged intent after interruption")
        let owner = Task { () -> NativeACKGateOutcome in
            do { try await adapter.bootstrap(session, handoff: handoff); return .acknowledged }
            catch { return .failure(error) }
        }
        do {
            try await transport.waitForEntry(handoff.contentSHA256)
            owner.cancel()
            let interrupted = await owner.value
            XCTAssertNotEqual(interrupted, .acknowledged)
            let gate = await transport.snapshot()
            XCTAssertTrue(gate.completedDigests.isEmpty)
            let pending = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(pending["status"] as? String, "bootstrapping")
            XCTAssertEqual(pending["handoffSHA256"] as? String, handoff.contentSHA256)
            let restarted = try ForgeNativeSessionHostAdapter(storageDirectory: root,
                transport: LocalLogicalSessionTransport())
            let restored = try await restarted.session(forIdempotencyKey: request.idempotencyKey)
            XCTAssertEqual(restored, session)
            try await restarted.bootstrap(session, handoff: handoff)
            let acknowledgement = try await restarted.awaitAcknowledgement(
                session: session, handoffID: handoff.handoffID, timeout: .seconds(1))
            XCTAssertEqual(acknowledgement.handoffID, handoff.handoffID)
            XCTAssertEqual(acknowledgement.successorSessionID, session.id)
            let committed = try nativeACKGateRecord(root: root, sessionID: session.id)
            XCTAssertEqual(committed["status"] as? String, "acknowledged")
            XCTAssertEqual(committed["handoffSHA256"] as? String, handoff.contentSHA256)
        } catch {
            await finishNativeACKGate(transport, tasks: [owner])
            throw error
        }
        await finishNativeACKGate(transport, tasks: [owner])
    }

    private func finishNativeACKGate(
        _ transport: NativeACKRevisionGateTransport,
        tasks: [Task<NativeACKGateOutcome, Never>]
    ) async {
        await transport.close()
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
    }

    private func nativeACKGateRecord(root: URL, sessionID: String) throws -> [String: Any] {
        let ledgerURL = root.appendingPathComponent("native-session-ledger.json")
        let size = try XCTUnwrap(ledgerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThanOrEqual(size, ForgeNativeSessionHostAdapter.maximumLedgerBytes)
        guard size <= ForgeNativeSessionHostAdapter.maximumLedgerBytes else {
            throw NativeHostPluginError.storageLimit
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL))
        let ledger = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(ledger["schemaVersion"] as? Int, 1)
        let rows = try XCTUnwrap(ledger["records"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first { $0["sessionID"] as? String == sessionID })
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
        contextUsed: Int = 28_000,
        nextAction: String = "Continue automatically",
        nextActionSuccessCondition: String = "Exact bootstrap acknowledgement is accepted"
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
                "action": nextAction,
                "command": "",
                "success_condition": nextActionSuccessCondition,
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
        let initialized = try memory.initializeUnchecked(path: project.path)
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

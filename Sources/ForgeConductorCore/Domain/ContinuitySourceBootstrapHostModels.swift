// Native source bootstrap exchanges only compact identity until an exact,
// manager-owned context_get has produced a durable retrieval proof.

import Foundation

public struct SourceBootstrapRequest: Sendable, Equatable {
    // The public facade supports the separately compiled native host plugin.
    // Only the manager can issue it from an accepted canonical envelope.
    let envelope: ContinuitySourceBootstrapEnvelope
    public let candidateID: UUID
    public let grantID: UUID
    public let modelKey: String
    public let idempotencyKey: String
    public let expectedPayloadSHA256: String
    public let expectedToolResultSHA256: String
    public let maximumOutputBytes: Int
    public let expectedPayloadByteCount: Int
    public let continuationInputBytes: Int

    public var operationID: UUID { envelope.operationID }
    public var runID: RunID { envelope.runID }
    public var projectID: ProjectID { envelope.authorization.projectID }
    public var projectGeneration: ProjectGeneration { envelope.authorization.projectGeneration }
    public var sourceIdentity: ContinuityHandoffIdentity { envelope.sourceIdentity }
    public var handoffID: UUID { envelope.handoffID }
    public var handoffSHA256: String { envelope.envelopeSHA256 }
    public var bootstrapNonce: UUID { envelope.bootstrapNonce }
    public var sessionID: String { candidateID.uuidString.lowercased() }

    init(envelope: ContinuitySourceBootstrapEnvelope, candidateID: UUID, grantID: UUID,
         modelKey: String, idempotencyKey: String) throws {
        let verified = try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: envelope.canonicalEnvelopeJSON)
        guard verified == envelope, idempotencyKey.utf8.count <= 768,
              envelope.authorization.authorizationScope.allowedTools.contains("context_get") else {
            throw ContinuityIngressError.invalidRequest("source bootstrap request")
        }
        try ManagedModelProviderContract.validateIdempotencyKey(idempotencyKey)
        guard !modelKey.isEmpty, modelKey.utf8.count <= ManagedModelProviderContract.maximumModelKeyBytes else {
            throw ManagedModelProviderContractError.invalidValue("model key is empty or oversized")
        }
        let packet = try JSONSerialization.jsonObject(with: envelope.acceptance.source.canonicalPacketJSON)
        let payload: [String: Any] = ["ok": true, "found": true, "packet": packet,
            "continuity_id": envelope.sourceIdentity.continuityID, "revision": envelope.sourceIdentity.revision,
            "packet_sha256": envelope.sourceIdentity.packetSHA256]
        let output = try ForgeJSONCanonicalizationV1.data(from: payload)
        let fullResult = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": payload])
        let limit = min(65_536, envelope.authorization.authorizationScope.maximumInlineOutputBytes)
        guard fullResult.count <= limit else {
            throw ContinuityIngressError.capacityExceeded("source bootstrap tool output bytes")
        }
        self.envelope = envelope
        self.candidateID = candidateID
        self.grantID = grantID
        self.modelKey = modelKey
        self.idempotencyKey = idempotencyKey
        self.expectedPayloadSHA256 = JSONSupport.sha256Hex(output)
        self.expectedToolResultSHA256 = JSONSupport.sha256Hex(fullResult)
        self.maximumOutputBytes = limit
        self.expectedPayloadByteCount = output.count
        // Quotation marks maximize JSON escaping for a bounded provider call ID.
        // This exposes a byte cost, not a source payload or evidence of retrieval.
        self.continuationInputBytes = try ForgeJSONCanonicalizationV1.data(from: [[
            "type": "function_call_output",
            "call_id": String(repeating: "\"", count: ManagedModelProviderContract.maximumIdentifierBytes),
            "output": String(decoding: output, as: UTF8.self),
        ]]).count
    }
}

public struct SourceBootstrapContextResult: Sendable, Equatable {
    let proof: ContinuityBootstrapRetrievalProof
    public var grantID: UUID { proof.grantID }
    public var candidateID: UUID { proof.candidateID }
    public var operationID: UUID { proof.operationID }
    public var runID: RunID { proof.runID }
    public var sourceIdentity: ContinuityHandoffIdentity { proof.sourceIdentity }
    public var bootstrapNonce: UUID { proof.bootstrapNonce }
    public var handoffSHA256: String { proof.handoffSHA256 }
    public var providerTurnID: UUID { proof.providerTurnID }
    public var providerResponseID: String { proof.providerResponseID }
    public var providerCallID: String { proof.providerCallID }
    public var toolInvocationID: UUID { proof.toolInvocationID }
    public var outputJSON: Data { proof.canonicalPayloadJSON }
    public var payloadOutputSHA256: String { proof.payloadOutputSHA256 }
    public var toolResultSHA256: String { proof.toolResultSHA256 }
    public var proofSHA256: String { proof.proofSHA256 }

    init(request: SourceBootstrapRequest, proof: ContinuityBootstrapRetrievalProof) throws {
        self.proof = proof
        try validate(request: request)
    }

    public func validate(request: SourceBootstrapRequest) throws {
        guard grantID == request.grantID, candidateID == request.candidateID,
              operationID == request.operationID, runID == request.runID,
              sourceIdentity == request.sourceIdentity, bootstrapNonce == request.bootstrapNonce,
              handoffSHA256 == request.handoffSHA256,
              proof.canonicalToolResultJSON.count <= request.maximumOutputBytes,
              outputJSON.count <= request.maximumOutputBytes,
              payloadOutputSHA256 == request.expectedPayloadSHA256,
              toolResultSHA256 == request.expectedToolResultSHA256,
              JSONSupport.sha256Hex(outputJSON) == payloadOutputSHA256,
              JSONSupport.sha256Hex(proof.canonicalToolResultJSON) == toolResultSHA256,
              JSONSupport.sha256Hex(proof.canonicalProofJSON) == proofSHA256 else {
            throw ContinuityIngressError.integrityFailure("source bootstrap retrieval proof differs from request")
        }
    }
}

public struct SourceBootstrapReceipt: Sendable, Equatable {
    public let bootstrap: BootstrapReceipt
    public let retrieval: SourceBootstrapContextResult
    public let rootTurn: ProviderTurn
    public let acknowledgementTurn: ProviderTurn

    public init(bootstrap: BootstrapReceipt, retrieval: SourceBootstrapContextResult,
                rootTurn: ProviderTurn, acknowledgementTurn: ProviderTurn) {
        self.bootstrap = bootstrap
        self.retrieval = retrieval
        self.rootTurn = rootTurn
        self.acknowledgementTurn = acknowledgementTurn
    }
}

public protocol SourceBootstrapExecuting: Sendable {
    /// Revalidates live manager authority and persists the exact intent. A
    /// completed durable turn is returned on replay, avoiding another dispatch.
    func prepareProviderTurn(intent: ProviderTurnIntent, input: Data, tools: [Data],
        capabilities: ProviderCapabilities, totalBootstrapInputBytes: Int) async throws -> ProviderTurn?
    /// Persists the actual root turn and executes its sole exact context_get
    /// through the existing broker, recording proof before returning its bytes.
    func retrieveContext(rootIntent: ProviderTurnIntent, rootTurn: ProviderTurn) async throws -> SourceBootstrapContextResult
    /// Persists the actual acknowledgement turn; activation remains manager-owned.
    func recordAcknowledgement(intent: ProviderTurnIntent, turn: ProviderTurn) async throws
}

public protocol SourceBootstrapHostAdapter: Sendable {
    func createSourceAndBootstrap(request: SourceBootstrapRequest,
        executor: any SourceBootstrapExecuting) async throws -> SourceBootstrapReceipt
}

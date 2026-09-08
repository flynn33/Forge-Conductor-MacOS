import Foundation

enum NativeSourceConversationError: Error, Sendable, Equatable {
    case notFound, conflict, integrityFailure, capacityExceeded, leaseUnavailable
    case sourceFenced, ownerManaged, cancelled, deadlineExceeded, outcomeUnknown
    case budgetExceeded, unsupportedProvider, invalidRequest(String)
}
enum NativeSourceConversationState: String, Codable, Sendable {
    case idle, active, stopped, sourceFenced = "source_fenced"
    case reconciliationRequired = "reconciliation_required"
}
enum NativeSourceProviderStageState: String, Codable, Sendable {
    case prepared, submitted, accepted, outcomeUnknown = "outcome_unknown"
    case cancelledBeforeDispatch = "cancelled_before_dispatch"
}
struct NativeSourceConversationDescriptor: Sendable {
    let conversationID: UUID, taskID: UUID, capabilityID: UUID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let assignmentSHA256: String, providerID: String, adapterID: String, modelKey: String
    let state: NativeSourceConversationState
    let revision: Int64
    let activeStageID: UUID?
    let parentResponseID: String?
    let cancelled: Bool
    let stageCount: Int
    let createdAt: String, updatedAt: String
}
struct NativeSourceTurnPreparationRequest: Sendable {
    let requestID: UUID, conversationID: UUID
    let userInput: String
    init(requestID: UUID, conversationID: UUID, userInput: String) throws {
        guard !userInput.isEmpty, userInput.utf8.count <= 16_384 else {
            throw NativeSourceConversationError.invalidRequest("input")
        }
        self.requestID = requestID; self.conversationID = conversationID; self.userInput = userInput
    }
}
enum NativeSourceProviderRequest: Sendable {
    case root(ProviderRootRequest)
    case continuation(ProviderContinuationRequest)
}
struct NativeSourcePreparedTurn: Sendable {
    let conversationID: UUID, taskID: UUID, stageID: UUID, requestID: UUID
    let ordinal: Int
    let state: NativeSourceProviderStageState
    let request: NativeSourceProviderRequest
    let intentSHA256: String, deadline: String
    let priorUsage: ProviderUsage?
    let priorContextSerializedBytes: Int
    let frozenCeilings: NativeSourceBudgetCeilings?
    let retainedPreflight: ProviderRequestPreflight?
    let retainedCapabilities: ProviderCapabilities?
}
struct NativeSourceBudgetCeilings: Codable, Sendable, Equatable {
    let effectiveContextTokens: Int, maximumOutputTokens: Int
    let tools: BudgetToolPolicy
    let reserves: ContextBudgetReserves
    let checkpointRatio: Double, rolloverRatio: Double, emergencyRatio: Double
    func validated() throws -> Self {
        guard (1...ManagedModelProviderContract.maximumContextTokens).contains(effectiveContextTokens),
              (1...effectiveContextTokens).contains(maximumOutputTokens) else { throw NativeSourceConversationError.budgetExceeded }
        _ = try tools.validated(); _ = try reserves.fixedTotal()
        guard checkpointRatio.isFinite, rolloverRatio.isFinite, emergencyRatio.isFinite, checkpointRatio > 0,
              checkpointRatio < rolloverRatio, rolloverRatio < emergencyRatio, emergencyRatio <= 1 else {
            throw NativeSourceConversationError.budgetExceeded
        }
        return self
    }
}
struct NativeSourceProviderBudgetApproval: Sendable {
    let policySelection: BudgetPolicySelection
    let effectiveContextTokens: Int, retainedInputTokens: Int, futureReserveTokens: Int
    let limits: ProviderExecutionLimits
    let ceilings: NativeSourceBudgetCeilings
    let accounting: ContextBudgetAccounting
    let source: ContextBudgetUsageSource
    let confidence: Double
    let action: ContextBudgetAction
    init(policySelection: BudgetPolicySelection, effectiveContextTokens: Int, retainedInputTokens: Int,
         futureReserveTokens: Int, limits: ProviderExecutionLimits, ceilings: NativeSourceBudgetCeilings, accounting: ContextBudgetAccounting,
         source: ContextBudgetUsageSource, confidence: Double, action: ContextBudgetAction) throws {
        _ = try policySelection.policy.validated()
        _ = try accounting.validated(); _ = try ceilings.validated()
        guard ceilings.effectiveContextTokens == effectiveContextTokens, ceilings.maximumOutputTokens >= limits.maximumOutputTokens else { throw NativeSourceConversationError.budgetExceeded }
        guard confidence.isFinite, (0...1).contains(confidence), accounting.retainedInputTokens == retainedInputTokens,
              accounting.futureReserveTokens == futureReserveTokens else { throw NativeSourceConversationError.budgetExceeded }
        let total = retainedInputTokens.addingReportingOverflow(futureReserveTokens)
        guard retainedInputTokens >= 0, futureReserveTokens >= limits.maximumOutputTokens,
              !total.overflow, total.partialValue <= effectiveContextTokens,
              effectiveContextTokens <= ManagedModelProviderContract.maximumContextTokens else {
            throw NativeSourceConversationError.budgetExceeded
        }
        self.policySelection = policySelection; self.effectiveContextTokens = effectiveContextTokens
        self.retainedInputTokens = retainedInputTokens; self.futureReserveTokens = futureReserveTokens; self.limits = limits; self.ceilings = ceilings
        self.accounting = accounting; self.source = source; self.confidence = confidence; self.action = action
    }
}
struct NativeSourceProviderOutputBudget: Sendable {
    let conversationID: UUID, stageID: UUID
    let callOrdinal: Int
    let configurationFingerprintSHA256: String, priorOutputsSHA256: String
    let maximumCanonicalToolResultBytes: Int, maximumEscapedPayloadBytes: Int, maximumResultTokens: Int
    init(conversationID: UUID, stageID: UUID, callOrdinal: Int, configurationFingerprintSHA256: String,
         priorOutputsSHA256: String, maximumCanonicalToolResultBytes: Int,
         maximumEscapedPayloadBytes: Int, maximumResultTokens: Int) throws {
        guard (0..<16).contains(callOrdinal), ContinuityIngressLimits.validSHA256(configurationFingerprintSHA256),
              ContinuityIngressLimits.validSHA256(priorOutputsSHA256),
              (1...1_048_576).contains(maximumCanonicalToolResultBytes),
              (1...524_288).contains(maximumEscapedPayloadBytes), (1...1_048_576).contains(maximumResultTokens) else {
            throw NativeSourceConversationError.budgetExceeded
        }
        self.conversationID = conversationID; self.stageID = stageID; self.callOrdinal = callOrdinal
        self.configurationFingerprintSHA256 = configurationFingerprintSHA256; self.priorOutputsSHA256 = priorOutputsSHA256
        self.maximumCanonicalToolResultBytes = maximumCanonicalToolResultBytes
        self.maximumEscapedPayloadBytes = maximumEscapedPayloadBytes; self.maximumResultTokens = maximumResultTokens
    }
}
struct NativeSourceAcceptedProviderTurn: Sendable {
    let prepared: NativeSourcePreparedTurn
    let turn: ProviderTurn
    let calls: [NativeSourceProviderCallReference]
}
enum NativeSourceProviderPostAdmission: Sendable {
    case dispatch(NativeSourceProviderDispatchClaim)
    case accepted(NativeSourceAcceptedProviderTurn)
    case inProgress
    case outcomeUnknown
}
enum NativeSourceProviderOutcome: Sendable { case unknown, cancelledBeforeDispatch }
enum NativeSourceCapabilityCheckOutcome: Sendable { case completed, unknown }
struct ResolvedNativeSourceProviderCall: Sendable {
    let reference: NativeSourceProviderCallReference
    let providerOperationID: UUID
    let responseID: String, callID: String, toolName: String
    let canonicalArgumentsJSON: Data
    let key: NativeSourceRequestKey
    let priorOutputsSHA256: String
    let prepared: NativeSourcePreparedTurn
    let attachment: AuthenticatedContinuityTaskAttachment
    let acceptedUsage: ProviderUsage?
    let retainedContextSerializedBytes: Int
}
struct NativeSourceProviderCallOutput: Sendable {
    let reference: NativeSourceProviderCallReference
    let responseID: String, callID: String
    let reservationID: UUID
    let canonicalToolResultJSON: Data, canonicalPayloadJSON: Data
    let resultSHA256: String, payloadSHA256: String
    let readyHandoffCommitted: Bool
    let recordedAt: String
}
struct NativeSourceConversationCancellationReceipt: Sendable {
    let conversationID: UUID, taskID: UUID, requestID: UUID, cancelRequestID: UUID
    let alreadyRequested: Bool
    let pendingProviderOperationID: UUID?
    let recordedAt: String
}
struct NativeSourceBudgetCarryover: Codable, Sendable, Equatable {
    let conversationID: UUID, taskID: UUID
    let runID: RunID
    let acceptanceSHA256: String
    let ceilings: NativeSourceBudgetCeilings
    let priorSourceReadCallsAtEnrollment: Int
    let providerStageCount: Int, admittedProviderCalls: Int, observedInputTokens: Int, observedOutputTokens: Int, exactUsageStageCount: Int
    let journalSHA256: String
}
struct NativeSourceRecoveryReference: Sendable {
    let rowID: Int64
    let conversationID: UUID, taskID: UUID, requestID: UUID, stageID: UUID
}
struct NativeSourceRecoveryPage: Sendable {
    let references: [NativeSourceRecoveryReference]
    let nextRowID: Int64?
}

// Stored bytes are independently bounded and canonically re-encoded on every read.
// Provider execution receipts remain non-Codable; only this private journal projection is stored.
struct NativeSourceStoredLimits: Codable, Sendable {
    let output: Int, request: Int, response: Int, text: Int, arguments: Int, json: Int, line: Int, event: Int
    let connect: Double, first: Double, idle: Double, total: Double
    init(_ v: ProviderExecutionLimits) {
        output = v.maximumOutputTokens; request = v.maximumRequestBytes; response = v.maximumResponseBytes
        text = v.maximumTextBytes; arguments = v.maximumToolArgumentBytes; json = v.maximumJSONBytes
        line = v.maximumSSELineBytes; event = v.maximumSSEEventBytes
        connect = v.connectTimeoutSeconds; first = v.firstByteTimeoutSeconds; idle = v.idleTimeoutSeconds; total = v.totalTimeoutSeconds
    }
    func value() throws -> ProviderExecutionLimits {
        try .init(maximumOutputTokens: output, maximumRequestBytes: request, maximumResponseBytes: response,
            maximumTextBytes: text, maximumToolArgumentBytes: arguments, maximumJSONBytes: json,
            maximumSSELineBytes: line, maximumSSEEventBytes: event, connectTimeoutSeconds: connect,
            firstByteTimeoutSeconds: first, idleTimeoutSeconds: idle, totalTimeoutSeconds: total)
    }
}
struct NativeSourceStoredPreflight: Codable, Sendable {
    let kind: String, model: String, revision: String, configurationSHA: String, bodySHA: String
    let bytes: Int
    let input: Int?
    let limits: NativeSourceStoredLimits
    init(_ v: ProviderRequestPreflight) {
        kind = v.kind.rawValue; model = v.modelKey; revision = v.configurationRevision
        configurationSHA = v.configurationFingerprintSHA256; bodySHA = v.bodySHA256; bytes = v.bodyByteCount
        limits = .init(v.limits); input = v.serializedInputByteCount
    }
    func value() throws -> ProviderRequestPreflight {
        guard let kind = ProviderRequestPreflight.Kind(rawValue: kind) else { throw NativeSourceConversationError.integrityFailure }
        return try .init(kind: kind, modelKey: model, configurationRevision: revision,
            configurationFingerprintSHA256: configurationSHA, limits: limits.value(), bodySHA256: bodySHA, bodyByteCount: bytes, serializedInputByteCount: input)
    }
}
struct NativeSourceStoredIntent: Codable, Sendable {
    let conversationID: UUID, taskID: UUID, capabilityID: UUID, stageID: UUID, requestID: UUID
    let epoch: Int64
    let ordinal: Int
    let assignmentSHA: String, providerID: String, modelKey: String, kind: String
    let parentResponseID: String?
    let input: Data
    let tools: [Data]
    let deadline: String
    let priorUsage: ProviderUsage?
    let logicalInputSHA: String
    // Missing fields identify retained schema-eight bytes; synthesized Codable
    // omits their nil values when checking the original canonical digest.
    let logicalInputVersion: Int?
    let logicalInput: String?
    func request() throws -> NativeSourceProviderRequest {
        let key = "source-provider:" + stageID.uuidString.lowercased()
        guard ordinal >= 1, ordinal <= 8, epoch > 0, ContinuityIngressLimits.validSHA256(assignmentSHA), ContinuityIngressLimits.validSHA256(logicalInputSHA),
              tools.count == 3, tools.allSatisfy({ $0.count <= 262_144 }), input.count <= 524_288 else {
            throw NativeSourceConversationError.integrityFailure
        }
        if let logicalInputVersion, let logicalInput {
            guard logicalInputVersion == 1, !logicalInput.isEmpty,
                  logicalInput.utf8.count <= 16_384,
                  JSONSupport.sha256Hex(Data(logicalInput.utf8)) == logicalInputSHA else {
                throw NativeSourceConversationError.integrityFailure
            }
        } else if logicalInputVersion != nil || logicalInput != nil {
            throw NativeSourceConversationError.integrityFailure
        }
        _ = try NativeTaskValue.date(deadline)
        if kind == "root" {
            guard parentResponseID == nil, let text = String(data: input, encoding: .utf8) else { throw NativeSourceConversationError.integrityFailure }
            return .root(try .init(operationID: stageID, idempotencyKey: key, modelKey: modelKey, input: text, tools: tools))
        }
        guard kind == "user_continuation" || kind == "tool_continuation", let parentResponseID else {
            throw NativeSourceConversationError.integrityFailure
        }
        return .continuation(try .init(operationID: stageID, idempotencyKey: key, modelKey: modelKey,
            previousResponseID: parentResponseID, input: input, tools: tools))
    }
}
struct NativeSourceStoredConversation: Codable, Sendable {
    let conversationID: UUID, taskID: UUID, capabilityID: UUID, requestID: UUID
    let projectID: ProjectID, projectGeneration: ProjectGeneration
    let callerBindingID: UUID, sourceBindingID: UUID
    let assignmentSHA: String, authorizationSHA: String, scopeSHA: String
    let providerID: String, adapterID: String, modelKey: String
    let initialPolicy: BudgetPolicySelection
    let priorSourceReadCallsAtEnrollment: Int
    let sourceLimits: NativeTaskSourceLimits
    let createdAt: String
}
/// Retained budget evidence. Construction is not execution authority; CP owns
/// its future write CAS and all claim issuance.
struct NativeSourceStoredBudgetDisposition: Codable, Sendable {
    let version: Int
    let metadata: NativeSourceBudgetMetadata
    let fenceRevision: Int64
    let recordedAt: String
    let storageDeadline: String?
    enum CodingKeys: String, CodingKey {
        case version, metadata
        case fenceRevision = "fence_revision"
        case recordedAt = "recorded_at"
        case storageDeadline = "storage_deadline"
    }
    var binding: NativeSourceBudgetBinding {
        switch metadata {
        case .pressure(let value): value.observation.binding
        case .blocked(let value): value.binding
        }
    }
    func validated() throws -> Self {
        let next = binding.conversationRevision.addingReportingOverflow(1)
        guard version == 1, !next.overflow, fenceRevision == next.partialValue else {
            throw NativeSourceConversationError.integrityFailure
        }
        _ = try NativeTaskValue.date(recordedAt)
        switch metadata {
        case .pressure:
            guard let storageDeadline, let recorded = ISO8601.date(from: recordedAt),
                  let deadline = ISO8601.date(from: try NativeTaskValue.date(storageDeadline)),
                  deadline > recorded, deadline.timeIntervalSince(recorded) <= 300 else {
                throw NativeSourceConversationError.integrityFailure
            }
        case .blocked:
            guard storageDeadline == nil else { throw NativeSourceConversationError.integrityFailure }
        }
        _ = try NativeSourceJournalCoding.encode(self, maximum: NativeSourceBudgetMetadata.maximumStoredBytes)
        return self
    }
}
struct NativeSourceStoredPost: Codable, Sendable {
    let preflight: NativeSourceStoredPreflight
    let capabilities: ProviderCapabilities
    let policy: BudgetPolicySelection
    let retainedInputTokens: Int, futureReserveTokens: Int
    let ceilings: NativeSourceBudgetCeilings
    let accounting: ContextBudgetAccounting
    let source: ContextBudgetUsageSource
    let confidence: Double
    let action: ContextBudgetAction
}
enum NativeSourceJournalCoding {
    static let maximumIntentBytes = 1_048_576
    static let maximumTurnBytes = 4_194_304
    static let reservationBytes = 10_485_760
    static func encode<T: Encodable>(_ value: T, maximum: Int) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximum else { throw NativeSourceConversationError.capacityExceeded }
        let result = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: encoded))
        guard result.count <= maximum else { throw NativeSourceConversationError.capacityExceeded }
        return result
    }
    static func decode<T: Codable>(_ type: T.Type, _ json: String, sha: String, maximum: Int) throws -> T {
        let data = Data(json.utf8)
        guard data.count <= maximum, JSONSupport.sha256Hex(data) == sha else { throw NativeSourceConversationError.integrityFailure }
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value, maximum: maximum) == data else { throw NativeSourceConversationError.integrityFailure }
        return value
    }
    static func usage(_ usage: ProviderUsage) throws -> ProviderUsage {
        try .init(capacity: usage.capacity, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
            totalTokens: usage.totalTokens, source: usage.source, confidence: usage.confidence)
    }
    static func turn(_ turn: ProviderTurn) throws -> ProviderTurn {
        let calls = try turn.toolCalls.map { value in
            try ProviderToolCall(itemID: value.itemID, callID: value.callID, name: value.name, argumentsJSON: value.argumentsJSON)
        }
        return try .init(requestID: turn.requestID, responseID: turn.responseID, previousResponseID: turn.previousResponseID,
            providerID: turn.providerID, providerVersion: turn.providerVersion, modelKey: turn.modelKey,
            providerInstanceID: turn.providerInstanceID, messages: turn.messages, toolCalls: calls,
            structuredOutputJSON: turn.structuredOutputJSON, usage: turn.usage.map(usage), completed: turn.completed,
            finishReason: turn.finishReason, rawArtifactID: turn.rawArtifactID)
    }
}

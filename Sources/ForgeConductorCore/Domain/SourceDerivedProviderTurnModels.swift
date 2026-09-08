import Foundation

/// An immutable observation of the exact request authorized at first submission.
/// This is an internal read projection, not a credential or permission to POST.
struct SourceDerivedProviderTurnPreflightReceipt: Sendable, Equatable {
    let intent: ProviderTurnIntent
    let preflight: ProviderRequestPreflight
    let capabilities: ProviderCapabilities
    let receiptSHA256: String
    let recordedAt: String
}

/// Actual context consumed by the newly accepted successor before ordinary work.
/// Historical source usage is deliberately absent; this read grants no dispatch authority.
struct SourceDerivedBootstrapAcknowledgement: Sendable, Equatable {
    let turn: ProviderTurn
    let preflight: ProviderRequestPreflight
    let capabilities: ProviderCapabilities
    let retainedContextSerializedBytes: Int
    let acknowledgementProviderTurnID: UUID
    let activationReceiptSHA256: String
}

enum SourceDerivedProviderTurnAdmission: Sendable {
    /// Only the transaction that first stores the receipt and submits the intent returns this case.
    case dispatch
    case lookupOnly(ProviderTurnRecord)
    case completed(ProviderTurnRecord)
}

struct SourceDerivedProviderTurnStoredPreflight: Codable, Sendable {
    static let maximumBytes = 32_768
    let version: Int
    let intent: ProviderTurnIntentRecord
    let preflight: NativeSourceStoredPreflight
    let capabilities: ProviderCapabilities
    let submissionID: UUID
    let leaseOwner: String
    let leaseEpoch: UInt64
    let recordedAt: String

    func validatedReceipt(sha256: String) throws -> SourceDerivedProviderTurnPreflightReceipt {
        guard version == 1, leaseEpoch > 0, !leaseOwner.isEmpty, leaseOwner.utf8.count <= 512,
              ISO8601.date(from: recordedAt) != nil else { throw NativeSourceConversationError.integrityFailure }
        let c = capabilities
        let validatedCapabilities = try ProviderCapabilities(providerID: c.providerID, providerVersion: c.providerVersion,
            modelKey: c.modelKey, providerInstanceID: c.providerInstanceID, contextLength: c.contextLength,
            maximumContextLength: c.maximumContextLength, statefulResponses: c.statefulResponses,
            streaming: c.streaming, customTools: c.customTools, mcp: c.mcp, structuredOutput: c.structuredOutput,
            usageReporting: c.usageReporting, idempotencyLookup: c.idempotencyLookup,
            capabilityFingerprintSHA256: c.capabilityFingerprintSHA256)
        return try .init(intent: .init(turnID: intent.turnID, runID: intent.runID, sessionID: intent.sessionID,
            operationID: intent.operationID, projectID: intent.projectID, projectGeneration: intent.projectGeneration,
            kind: intent.kind, idempotencyKey: intent.idempotencyKey, previousResponseID: intent.previousResponseID,
            inputSHA256: intent.inputSHA256, toolSchemaSHA256: intent.toolSchemaSHA256),
            preflight: preflight.value(), capabilities: validatedCapabilities, receiptSHA256: sha256, recordedAt: recordedAt)
    }
}

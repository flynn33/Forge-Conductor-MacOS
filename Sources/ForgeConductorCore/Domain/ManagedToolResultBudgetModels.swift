import Foundation

/// The actual ordered function outputs for one observed provider response.
/// The SHA covers the canonical complete output array; the byte count comes
/// from the native transport's serialization of that same array.
public struct ManagedToolResultPrefix: Sendable, Equatable {
    public let providerResponseID: String
    public let outputCount: Int
    public let lastProviderCallID: String?
    public let canonicalPrefixSHA256: String
    public let serializedInputByteCount: Int

    public init(providerResponseID: String, outputCount: Int, lastProviderCallID: String?,
                canonicalPrefixSHA256: String, serializedInputByteCount: Int) throws {
        self.providerResponseID = providerResponseID; self.outputCount = outputCount
        self.lastProviderCallID = lastProviderCallID; self.canonicalPrefixSHA256 = canonicalPrefixSHA256
        self.serializedInputByteCount = serializedInputByteCount
        _ = try validated()
    }

    func validated() throws -> Self {
        guard ManagedToolResultBudgetValidation.identifier(providerResponseID, maximum: 1_024),
              (0...ManagedModelProviderContract.maximumToolCallCount).contains(outputCount),
              ManagedToolResultBudgetValidation.digest(canonicalPrefixSHA256) else {
            throw ContextBudgetError.invalidObservation("invalid tool output prefix")
        }
        if outputCount == 0 {
            guard lastProviderCallID == nil, serializedInputByteCount == 0,
                  canonicalPrefixSHA256 == JSONSupport.sha256Hex(Data("[]".utf8)) else {
                throw ContextBudgetError.invalidObservation("invalid empty tool output prefix")
            }
        } else {
            guard let lastProviderCallID,
                  ManagedToolResultBudgetValidation.identifier(lastProviderCallID, maximum: 512),
                  (1...ManagedModelProviderContract.maximumContinuationInputBytes).contains(serializedInputByteCount) else {
                throw ContextBudgetError.invalidObservation("invalid tool output prefix bounds")
            }
        }
        return self
    }
}

/// A local projection only. The placeholder request contains the already
/// recorded outputs followed by this call's nonempty "0" placeholder.
public struct ManagedToolResultProjection: Sendable {
    public let priorPrefix: ManagedToolResultPrefix
    public let providerCallID: String
    public let continuationPreflight: ProviderRequestPreflight
    public let maximumToolResultBytes: Int
    public let toolSchemaSHA256: String

    public init(priorPrefix: ManagedToolResultPrefix, providerCallID: String,
                continuationPreflight: ProviderRequestPreflight, maximumToolResultBytes: Int,
                toolSchemaSHA256: String) throws {
        _ = try priorPrefix.validated()
        guard ManagedToolResultBudgetValidation.identifier(providerCallID, maximum: 512),
              priorPrefix.outputCount < ManagedModelProviderContract.maximumToolCallCount,
              continuationPreflight.kind == .continuation,
              let inputBytes = continuationPreflight.serializedInputByteCount,
              inputBytes > priorPrefix.serializedInputByteCount,
              (1...65_536).contains(maximumToolResultBytes),
              ManagedToolResultBudgetValidation.digest(toolSchemaSHA256) else {
            throw ContextBudgetError.invalidObservation("invalid tool result projection")
        }
        self.priorPrefix = priorPrefix; self.providerCallID = providerCallID
        self.continuationPreflight = continuationPreflight; self.maximumToolResultBytes = maximumToolResultBytes
        self.toolSchemaSHA256 = toolSchemaSHA256
    }
}

/// Source-derived execution requires this refinement. Existing ordinary
/// evaluators remain source compatible and do not silently admit projections.
public protocol ManagedRunToolResultBudgetEvaluating: ManagedRunBudgetEvaluating {
    func seedSourceProviderTurn(run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        turn: ProviderTurn, retainedContextSerializedBytes: Int) async throws -> ContextBudgetAction
    func evaluateBeforeToolResult(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities, projection: ManagedToolResultProjection) async throws -> ContextBudgetAction
    func observeToolResultPrefix(run: AutonomousRunRecord, sessionID: String,
        capabilities: ProviderCapabilities, prefix: ManagedToolResultPrefix) async throws -> ContextBudgetAction
}

/// Compact stamps keep one provider batch inside the existing budget record.
/// Raw call IDs are hashed so the maximum batch remains below storage bounds.
struct ManagedToolResultPrefixStamp: Codable, Sendable, Equatable {
    let callSHA256: String
    let prefixSHA256: String
    let inputBytes: Int
    init(_ prefix: ManagedToolResultPrefix) throws {
        _ = try prefix.validated()
        guard let call = prefix.lastProviderCallID else {
            throw ContextBudgetError.invalidObservation("an empty prefix has no result stamp")
        }
        callSHA256 = JSONSupport.sha256Hex(Data(call.utf8))
        prefixSHA256 = prefix.canonicalPrefixSHA256; inputBytes = prefix.serializedInputByteCount
    }
}

public struct ManagedToolResultAccounting: Codable, Sendable, Equatable {
    public let providerResponseID: String
    public let providerTurnSHA256: String
    let expectedCallSHA256: [String]
    let prefixes: [ManagedToolResultPrefixStamp]
    let seedRetainedContextSerializedBytes: Int?

    init(providerResponseID: String, providerTurnSHA256: String, expectedCallSHA256: [String],
         prefixes: [ManagedToolResultPrefixStamp] = [], seedRetainedContextSerializedBytes: Int? = nil) throws {
        self.providerResponseID = providerResponseID; self.providerTurnSHA256 = providerTurnSHA256
        self.expectedCallSHA256 = expectedCallSHA256; self.prefixes = prefixes
        self.seedRetainedContextSerializedBytes = seedRetainedContextSerializedBytes
        _ = try validated()
    }

    func validated() throws -> Self {
        guard ManagedToolResultBudgetValidation.identifier(providerResponseID, maximum: 1_024),
              ManagedToolResultBudgetValidation.digest(providerTurnSHA256),
              expectedCallSHA256.count <= ManagedModelProviderContract.maximumToolCallCount,
              expectedCallSHA256.allSatisfy(ManagedToolResultBudgetValidation.digest),
              Set(expectedCallSHA256).count == expectedCallSHA256.count,
              prefixes.count <= expectedCallSHA256.count,
              seedRetainedContextSerializedBytes.map({ (1...(64 * 1_024 * 1_024)).contains($0) }) ?? true else {
            throw ContextBudgetError.invalidObservation("invalid tool result accounting")
        }
        var priorBytes = 0
        var calls = Set<String>()
        for (index, prefix) in prefixes.enumerated() {
            guard ManagedToolResultBudgetValidation.digest(prefix.callSHA256),
                  ManagedToolResultBudgetValidation.digest(prefix.prefixSHA256),
                  calls.insert(prefix.callSHA256).inserted,
                  prefix.callSHA256 == expectedCallSHA256[index],
                  prefix.inputBytes > priorBytes,
                  prefix.inputBytes <= ManagedModelProviderContract.maximumContinuationInputBytes else {
                throw ContextBudgetError.invalidObservation("invalid retained tool output prefix")
            }
            priorBytes = prefix.inputBytes
        }
        return self
    }

    func validate(_ prefix: ManagedToolResultPrefix) throws {
        _ = try validated(); _ = try prefix.validated()
        guard prefix.providerResponseID == providerResponseID, prefix.outputCount <= prefixes.count else {
            throw ContextBudgetError.invalidObservation("tool output prefix is not retained")
        }
        if prefix.outputCount > 0 {
            guard prefixes[prefix.outputCount - 1] == (try ManagedToolResultPrefixStamp(prefix)) else {
                throw ContextBudgetError.invalidObservation("retained tool output prefix differs")
            }
        }
    }

    func appending(_ prefix: ManagedToolResultPrefix) throws -> Self {
        _ = try prefix.validated()
        guard prefix.providerResponseID == providerResponseID, prefix.outputCount == prefixes.count + 1 else {
            throw ContextBudgetError.invalidObservation("tool output prefix skipped an ordinal")
        }
        return try .init(providerResponseID: providerResponseID, providerTurnSHA256: providerTurnSHA256,
                         expectedCallSHA256: expectedCallSHA256, prefixes: prefixes + [ManagedToolResultPrefixStamp(prefix)],
                         seedRetainedContextSerializedBytes: seedRetainedContextSerializedBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case providerResponseID, providerTurnSHA256, expectedCallSHA256, prefixes, seedRetainedContextSerializedBytes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(providerResponseID: c.decode(String.self, forKey: .providerResponseID),
            providerTurnSHA256: c.decode(String.self, forKey: .providerTurnSHA256),
            expectedCallSHA256: c.decode([String].self, forKey: .expectedCallSHA256),
            prefixes: c.decode([ManagedToolResultPrefixStamp].self, forKey: .prefixes),
            seedRetainedContextSerializedBytes: c.decodeIfPresent(Int.self, forKey: .seedRetainedContextSerializedBytes))
    }
}

enum ManagedToolResultBudgetValidation {
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func identifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func turnSHA256(_ turn: ProviderTurn) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return JSONSupport.sha256Hex(try encoder.encode(turn))
    }
}

// ManagedModelProvider.swift
// What: Defines the provider-neutral contract for bounded managed model turns.
// How: Validated value models normalize capabilities, requests, terminal turns, tools, and usage.
// Why: Autonomy can drive a real provider without depending on one provider's wire protocol.

import Foundation

public enum ManagedModelProviderContract {
    public static let maximumIdentifierBytes = 1_024
    public static let maximumModelKeyBytes = 512
    public static let maximumVersionBytes = 256
    public static let maximumIdempotencyKeyBytes = 1_024
    public static let maximumInputBytes = 512 * 1_024
    public static let maximumToolCount = 128
    public static let maximumToolDefinitionBytes = 256 * 1_024
    public static let maximumContinuationInputBytes = 512 * 1_024
    public static let maximumMessageCount = 128
    public static let maximumMessageBytes = 512 * 1_024
    public static let maximumToolCallCount = 128
    public static let maximumToolArgumentBytes = 256 * 1_024
    public static let maximumStructuredOutputBytes = 512 * 1_024
    public static let maximumContextTokens = 16 * 1_024 * 1_024

    public static func validateIdempotencyKey(_ value: String) throws {
        try validateString(
            value,
            field: "idempotency key",
            maximumBytes: maximumIdempotencyKeyBytes
        )
    }

    fileprivate static func validateIdentifier(_ value: String, field: String) throws {
        try validateString(value, field: field, maximumBytes: maximumIdentifierBytes)
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ManagedModelProviderContractError.invalidValue("\(field) contains control characters")
        }
    }

    fileprivate static func validateString(
        _ value: String,
        field: String,
        maximumBytes: Int,
        permitsEmpty: Bool = false
    ) throws {
        guard (permitsEmpty || !value.isEmpty), value.utf8.count <= maximumBytes else {
            throw ManagedModelProviderContractError.invalidValue("\(field) is empty or oversized")
        }
    }

    fileprivate static func validateJSONObject(
        _ data: Data,
        field: String,
        maximumBytes: Int,
        permitsArray: Bool = false
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedModelProviderContractError.invalidValue("\(field) is empty or oversized")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManagedModelProviderContractError.invalidValue("\(field) is not valid JSON")
        }
        guard object is [String: Any] || (permitsArray && object is [Any]) else {
            throw ManagedModelProviderContractError.invalidValue(
                "\(field) must be a JSON object\(permitsArray ? " or array" : "")"
            )
        }
    }
}

public enum ManagedModelProviderContractError: Error, LocalizedError, Sendable, Equatable {
    case invalidValue(String)
    case unsupportedCapability(String)
    case incompleteTerminalResponse

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let detail): "Invalid managed-provider value: \(detail)"
        case .unsupportedCapability(let detail): "Managed-provider capability is unavailable: \(detail)"
        case .incompleteTerminalResponse: "Managed provider did not return a complete terminal response"
        }
    }
}

/// Provider-neutral recovery policy exposed across the Core/plugin boundary.
/// Concrete transports retain their detailed error types while the manager can
/// persist the correct run state without importing a provider implementation.
public enum ManagedProviderFailureDisposition: String, Sendable, Equatable {
    case waitingProvider = "waiting_provider"
    case blockedConfiguration = "blocked_configuration"
    case contextOverflow = "context_overflow"
    case cancelled
    case failedRecoverable = "failed_recoverable"
    case failedTerminal = "failed_terminal"
}

public protocol ManagedProviderFailure: Error, Sendable {
    var managedProviderFailureDisposition: ManagedProviderFailureDisposition { get }
    var managedProviderFailureCode: String { get }
    var managedProviderRetryDelay: TimeInterval? { get }
}

extension ManagedModelProviderContractError: ManagedProviderFailure {
    public var managedProviderFailureDisposition: ManagedProviderFailureDisposition {
        switch self {
        case .invalidValue, .unsupportedCapability: .failedTerminal
        case .incompleteTerminalResponse: .failedRecoverable
        }
    }

    public var managedProviderFailureCode: String {
        switch self {
        case .invalidValue: "managed_provider_invalid_value"
        case .unsupportedCapability: "managed_provider_unsupported_capability"
        case .incompleteTerminalResponse: "managed_provider_incomplete_terminal_response"
        }
    }

    public var managedProviderRetryDelay: TimeInterval? { nil }
}

public enum ProviderUsageSource: String, Codable, Sendable, Equatable {
    case providerExact = "provider_exact"
    case tokenizerExact = "tokenizer_exact"
    case serializedEstimate = "serialized_estimate"
    case providerOverflow = "provider_overflow"
}

public struct ProviderUsage: Codable, Sendable, Equatable {
    public let capacity: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let source: ProviderUsageSource
    public let confidence: Double

    public init(
        capacity: Int,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int? = nil,
        source: ProviderUsageSource,
        confidence: Double
    ) throws {
        let resolvedTotal = totalTokens ?? inputTokens + outputTokens
        guard (1...ManagedModelProviderContract.maximumContextTokens).contains(capacity),
              inputTokens >= 0,
              outputTokens >= 0,
              resolvedTotal >= inputTokens,
              resolvedTotal >= outputTokens,
              resolvedTotal <= ManagedModelProviderContract.maximumContextTokens * 2,
              confidence.isFinite,
              (0...1).contains(confidence) else {
            throw ManagedModelProviderContractError.invalidValue("provider usage is outside bounds")
        }
        self.capacity = capacity
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = resolvedTotal
        self.source = source
        self.confidence = confidence
    }
}

public struct ProviderToolCall: Codable, Sendable, Equatable {
    public let itemID: String?
    public let callID: String
    public let name: String
    public let argumentsJSON: Data

    public init(
        itemID: String? = nil,
        callID: String,
        name: String,
        argumentsJSON: Data
    ) throws {
        if let itemID {
            try ManagedModelProviderContract.validateIdentifier(itemID, field: "tool item ID")
        }
        try ManagedModelProviderContract.validateIdentifier(callID, field: "tool call ID")
        try ManagedModelProviderContract.validateString(
            name,
            field: "tool name",
            maximumBytes: 128
        )
        try ManagedModelProviderContract.validateJSONObject(
            argumentsJSON,
            field: "tool arguments",
            maximumBytes: ManagedModelProviderContract.maximumToolArgumentBytes
        )
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public enum ProviderFinishReason: String, Codable, Sendable, Equatable {
    case stop
    case toolCalls = "tool_calls"
}

public struct ProviderTurn: Codable, Sendable, Equatable {
    public let requestID: String
    public let responseID: String
    public let previousResponseID: String?
    public let providerID: String
    public let providerVersion: String
    public let modelKey: String
    public let providerInstanceID: String?
    public let messages: [String]
    public let toolCalls: [ProviderToolCall]
    public let structuredOutputJSON: Data?
    public let usage: ProviderUsage?
    public let completed: Bool
    public let finishReason: ProviderFinishReason
    public let rawArtifactID: String?

    public init(
        requestID: String,
        responseID: String,
        previousResponseID: String? = nil,
        providerID: String,
        providerVersion: String,
        modelKey: String,
        providerInstanceID: String? = nil,
        messages: [String],
        toolCalls: [ProviderToolCall],
        structuredOutputJSON: Data? = nil,
        usage: ProviderUsage?,
        completed: Bool,
        finishReason: ProviderFinishReason,
        rawArtifactID: String? = nil
    ) throws {
        try ManagedModelProviderContract.validateIdentifier(requestID, field: "provider request ID")
        try ManagedModelProviderContract.validateIdentifier(responseID, field: "provider response ID")
        if let previousResponseID {
            try ManagedModelProviderContract.validateIdentifier(
                previousResponseID,
                field: "previous provider response ID"
            )
        }
        try ManagedModelProviderContract.validateIdentifier(providerID, field: "provider ID")
        try ManagedModelProviderContract.validateString(
            providerVersion,
            field: "provider version",
            maximumBytes: ManagedModelProviderContract.maximumVersionBytes
        )
        try ManagedModelProviderContract.validateString(
            modelKey,
            field: "model key",
            maximumBytes: ManagedModelProviderContract.maximumModelKeyBytes
        )
        if let providerInstanceID {
            try ManagedModelProviderContract.validateIdentifier(
                providerInstanceID,
                field: "provider instance ID"
            )
        }
        guard messages.count <= ManagedModelProviderContract.maximumMessageCount,
              messages.reduce(into: 0, { $0 += $1.utf8.count })
                <= ManagedModelProviderContract.maximumMessageBytes,
              toolCalls.count <= ManagedModelProviderContract.maximumToolCallCount else {
            throw ManagedModelProviderContractError.invalidValue("provider turn payload is oversized")
        }
        if let structuredOutputJSON {
            try ManagedModelProviderContract.validateJSONObject(
                structuredOutputJSON,
                field: "structured output",
                maximumBytes: ManagedModelProviderContract.maximumStructuredOutputBytes,
                permitsArray: true
            )
        }
        if let rawArtifactID {
            try ManagedModelProviderContract.validateIdentifier(rawArtifactID, field: "raw artifact ID")
        }
        self.requestID = requestID
        self.responseID = responseID
        self.previousResponseID = previousResponseID
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.modelKey = modelKey
        self.providerInstanceID = providerInstanceID
        self.messages = messages
        self.toolCalls = toolCalls
        self.structuredOutputJSON = structuredOutputJSON
        self.usage = usage
        self.completed = completed
        self.finishReason = finishReason
        self.rawArtifactID = rawArtifactID
    }
}

public struct ProviderCapabilities: Codable, Sendable, Equatable {
    public let providerID: String
    public let providerVersion: String
    public let modelKey: String
    public let providerInstanceID: String
    public let contextLength: Int
    public let maximumContextLength: Int?
    public let statefulResponses: Bool
    public let streaming: Bool
    public let customTools: Bool
    public let mcp: Bool
    public let structuredOutput: Bool
    public let usageReporting: Bool
    public let idempotencyLookup: Bool
    public let capabilityFingerprintSHA256: String

    public init(
        providerID: String,
        providerVersion: String,
        modelKey: String,
        providerInstanceID: String,
        contextLength: Int,
        maximumContextLength: Int?,
        statefulResponses: Bool,
        streaming: Bool,
        customTools: Bool,
        mcp: Bool,
        structuredOutput: Bool,
        usageReporting: Bool,
        idempotencyLookup: Bool,
        capabilityFingerprintSHA256: String
    ) throws {
        try ManagedModelProviderContract.validateIdentifier(providerID, field: "provider ID")
        try ManagedModelProviderContract.validateString(
            providerVersion,
            field: "provider version",
            maximumBytes: ManagedModelProviderContract.maximumVersionBytes
        )
        try ManagedModelProviderContract.validateString(
            modelKey,
            field: "model key",
            maximumBytes: ManagedModelProviderContract.maximumModelKeyBytes
        )
        try ManagedModelProviderContract.validateIdentifier(
            providerInstanceID,
            field: "provider instance ID"
        )
        guard (1...ManagedModelProviderContract.maximumContextTokens).contains(contextLength),
              maximumContextLength.map({
                  $0 >= contextLength && $0 <= ManagedModelProviderContract.maximumContextTokens
              }) ?? true,
              capabilityFingerprintSHA256.count == 64,
              capabilityFingerprintSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw ManagedModelProviderContractError.invalidValue("provider capabilities are invalid")
        }
        self.providerID = providerID
        self.providerVersion = providerVersion
        self.modelKey = modelKey
        self.providerInstanceID = providerInstanceID
        self.contextLength = contextLength
        self.maximumContextLength = maximumContextLength
        self.statefulResponses = statefulResponses
        self.streaming = streaming
        self.customTools = customTools
        self.mcp = mcp
        self.structuredOutput = structuredOutput
        self.usageReporting = usageReporting
        self.idempotencyLookup = idempotencyLookup
        self.capabilityFingerprintSHA256 = capabilityFingerprintSHA256.lowercased()
    }
}

public struct ProviderRootRequest: Sendable, Equatable {
    public let operationID: UUID
    public let idempotencyKey: String
    public let modelKey: String
    public let input: String
    public let tools: [Data]
    public let structuredOutputSchema: Data?

    public init(
        operationID: UUID,
        idempotencyKey: String,
        modelKey: String,
        input: String,
        tools: [Data],
        structuredOutputSchema: Data? = nil
    ) throws {
        try ManagedModelProviderContract.validateIdempotencyKey(idempotencyKey)
        try ManagedModelProviderContract.validateString(
            modelKey,
            field: "model key",
            maximumBytes: ManagedModelProviderContract.maximumModelKeyBytes
        )
        try ManagedModelProviderContract.validateString(
            input,
            field: "root input",
            maximumBytes: ManagedModelProviderContract.maximumInputBytes
        )
        guard tools.count <= ManagedModelProviderContract.maximumToolCount else {
            throw ManagedModelProviderContractError.invalidValue("tool count exceeds the contract limit")
        }
        for tool in tools {
            try ManagedModelProviderContract.validateJSONObject(
                tool,
                field: "tool definition",
                maximumBytes: ManagedModelProviderContract.maximumToolDefinitionBytes
            )
        }
        if let structuredOutputSchema {
            try ManagedModelProviderContract.validateJSONObject(
                structuredOutputSchema,
                field: "structured output schema",
                maximumBytes: ManagedModelProviderContract.maximumToolDefinitionBytes
            )
        }
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.modelKey = modelKey
        self.input = input
        self.tools = tools
        self.structuredOutputSchema = structuredOutputSchema
    }

    public func validated() throws -> ProviderRootRequest {
        try ProviderRootRequest(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            modelKey: modelKey,
            input: input,
            tools: tools,
            structuredOutputSchema: structuredOutputSchema
        )
    }
}

public struct ProviderContinuationRequest: Sendable, Equatable {
    public let operationID: UUID
    public let idempotencyKey: String
    public let modelKey: String
    public let previousResponseID: String
    public let input: Data
    public let tools: [Data]

    public init(
        operationID: UUID,
        idempotencyKey: String,
        modelKey: String,
        previousResponseID: String,
        input: Data,
        tools: [Data]
    ) throws {
        try ManagedModelProviderContract.validateIdempotencyKey(idempotencyKey)
        try ManagedModelProviderContract.validateString(
            modelKey,
            field: "model key",
            maximumBytes: ManagedModelProviderContract.maximumModelKeyBytes
        )
        try ManagedModelProviderContract.validateIdentifier(
            previousResponseID,
            field: "previous provider response ID"
        )
        try ManagedModelProviderContract.validateJSONObject(
            input,
            field: "continuation input",
            maximumBytes: ManagedModelProviderContract.maximumContinuationInputBytes,
            permitsArray: true
        )
        guard tools.count <= ManagedModelProviderContract.maximumToolCount else {
            throw ManagedModelProviderContractError.invalidValue("tool count exceeds the contract limit")
        }
        for tool in tools {
            try ManagedModelProviderContract.validateJSONObject(
                tool,
                field: "tool definition",
                maximumBytes: ManagedModelProviderContract.maximumToolDefinitionBytes
            )
        }
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.modelKey = modelKey
        self.previousResponseID = previousResponseID
        self.input = input
        self.tools = tools
    }

    public func validated() throws -> ProviderContinuationRequest {
        try ProviderContinuationRequest(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            modelKey: modelKey,
            previousResponseID: previousResponseID,
            input: input,
            tools: tools
        )
    }
}

public protocol ManagedModelProvider: Sendable {
    var providerID: String { get }
    func probe() async throws -> ProviderCapabilities
    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn
    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn
    func lookup(idempotencyKey: String) async throws -> ProviderTurn?
    func cancel(requestID: String) async
}

// ForgeNativeSessionHostPlugin.swift
// What: Implements the native logical-session host used for autonomous rollover.
// How: An injected transport performs provider work while a bounded local ledger reconciles retries.
// Why: Forge can create, bootstrap, acknowledge, cancel, and recover sessions without GUI automation.

import Foundation
#if canImport(Security)
import Security
#endif
#if SWIFT_PACKAGE
import ForgeConductorCore
#endif

public enum LMStudioProviderError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case providerUnavailable
    case unauthorized
    case forbidden
    case endpointNotFound
    case conflict
    case rateLimited(retryNanoseconds: UInt64?)
    case serverFailure(status: Int)
    case contextOverflow
    case responseTruncated
    case deadlineExceeded(phase: String)
    case cancelled
    case malformedResponse(String)
    case limitExceeded(String)
    case receiptStorage(String)
    case syntheticProviderIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "LM Studio configuration is invalid: \(detail)"
        case .providerUnavailable: "LM Studio is unavailable"
        case .unauthorized: "LM Studio rejected the configured credential"
        case .forbidden: "LM Studio denied the request"
        case .endpointNotFound: "LM Studio endpoint or model was not found"
        case .conflict: "LM Studio reported a request conflict"
        case .rateLimited: "LM Studio rate limited the request"
        case .serverFailure(let status): "LM Studio returned server status \(status)"
        case .contextOverflow: "LM Studio reported that the active context limit was exceeded"
        case .responseTruncated: "LM Studio reported a truncated response"
        case .deadlineExceeded(let phase): "LM Studio request exceeded its \(phase) deadline"
        case .cancelled: "LM Studio request was cancelled"
        case .malformedResponse(let detail): "LM Studio returned an invalid response: \(detail)"
        case .limitExceeded(let detail): "LM Studio response exceeded the \(detail) limit"
        case .receiptStorage(let detail): "LM Studio receipt storage failed: \(detail)"
        case .syntheticProviderIdentifier: "LM Studio returned a synthetic provider identifier"
        }
    }
}

extension LMStudioProviderError: ManagedProviderFailure {
    public var managedProviderFailureDisposition: ManagedProviderFailureDisposition {
        switch self {
        case .invalidConfiguration, .unauthorized, .forbidden, .endpointNotFound:
            .blockedConfiguration
        case .providerUnavailable, .conflict, .rateLimited, .serverFailure, .deadlineExceeded:
            .waitingProvider
        case .contextOverflow:
            .contextOverflow
        case .responseTruncated, .receiptStorage:
            .failedRecoverable
        case .cancelled:
            .cancelled
        case .malformedResponse, .limitExceeded, .syntheticProviderIdentifier:
            .failedTerminal
        }
    }

    public var managedProviderFailureCode: String {
        switch self {
        case .invalidConfiguration: "lmstudio_invalid_configuration"
        case .providerUnavailable: "lmstudio_provider_unavailable"
        case .unauthorized: "lmstudio_unauthorized"
        case .forbidden: "lmstudio_forbidden"
        case .endpointNotFound: "lmstudio_endpoint_not_found"
        case .conflict: "lmstudio_conflict"
        case .rateLimited: "lmstudio_rate_limited"
        case .serverFailure: "lmstudio_server_failure"
        case .contextOverflow: "lmstudio_context_overflow"
        case .responseTruncated: "lmstudio_response_truncated"
        case .deadlineExceeded: "lmstudio_deadline_exceeded"
        case .cancelled: "lmstudio_cancelled"
        case .malformedResponse: "lmstudio_malformed_response"
        case .limitExceeded: "lmstudio_limit_exceeded"
        case .receiptStorage: "lmstudio_receipt_storage"
        case .syntheticProviderIdentifier: "lmstudio_synthetic_provider_identifier"
        }
    }

    public var managedProviderRetryDelay: TimeInterval? {
        guard case .rateLimited(let retryNanoseconds) = self,
              let retryNanoseconds else { return nil }
        return min(60, TimeInterval(retryNanoseconds) / 1_000_000_000)
    }
}

public struct LMStudioProviderConfiguration: Codable, Sendable, Equatable {
    public static let fileName = "lmstudio-provider.json"
    public static let maximumFileBytes = 64 * 1024

    public var revision: String = "0"
    public var baseURL: URL
    public var modelKey: String?
    public var keychainTokenReference: String?
    public var connectTimeoutSeconds: Double
    public var firstByteTimeoutSeconds: Double
    public var idleTimeoutSeconds: Double
    public var totalTimeoutSeconds: Double
    public var maximumJSONBytes: Int
    public var maximumRequestBytes: Int
    public var maximumSSELineBytes: Int
    public var maximumSSEEventBytes: Int
    public var maximumResponseBytes: Int
    public var maximumTextBytes: Int
    public var maximumToolArgumentBytes: Int
    public var maximumOutputTokens: Int

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:1234")!,
        modelKey: String? = nil,
        keychainTokenReference: String? = nil,
        connectTimeoutSeconds: Double = 5,
        firstByteTimeoutSeconds: Double = 15,
        idleTimeoutSeconds: Double = 30,
        totalTimeoutSeconds: Double = 120,
        maximumJSONBytes: Int = 1024 * 1024,
        maximumRequestBytes: Int = 512 * 1024,
        maximumSSELineBytes: Int = 64 * 1024,
        maximumSSEEventBytes: Int = 256 * 1024,
        maximumResponseBytes: Int = 2 * 1024 * 1024,
        maximumTextBytes: Int = 512 * 1024,
        maximumToolArgumentBytes: Int = 256 * 1024,
        maximumOutputTokens: Int = 4_096
    ) {
        self.baseURL = baseURL
        self.modelKey = modelKey
        self.keychainTokenReference = keychainTokenReference
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.firstByteTimeoutSeconds = firstByteTimeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.totalTimeoutSeconds = totalTimeoutSeconds
        self.maximumJSONBytes = maximumJSONBytes
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumSSELineBytes = maximumSSELineBytes
        self.maximumSSEEventBytes = maximumSSEEventBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumTextBytes = maximumTextBytes
        self.maximumToolArgumentBytes = maximumToolArgumentBytes
        self.maximumOutputTokens = maximumOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case baseURL = "base_url"
        case modelKey = "model_key"
        case keychainTokenReference = "keychain_token_reference"
        case connectTimeoutSeconds = "connect_timeout_seconds"
        case firstByteTimeoutSeconds = "first_byte_timeout_seconds"
        case idleTimeoutSeconds = "idle_timeout_seconds"
        case totalTimeoutSeconds = "total_timeout_seconds"
        case maximumJSONBytes = "maximum_json_bytes"
        case maximumRequestBytes = "maximum_request_bytes"
        case maximumSSELineBytes = "maximum_sse_line_bytes"
        case maximumSSEEventBytes = "maximum_sse_event_bytes"
        case maximumResponseBytes = "maximum_response_bytes"
        case maximumTextBytes = "maximum_text_bytes"
        case maximumToolArgumentBytes = "maximum_tool_argument_bytes"
        case maximumOutputTokens = "maximum_output_tokens"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try values.decode(URL.self, forKey: .baseURL),
            modelKey: try values.decodeIfPresent(String.self, forKey: .modelKey),
            keychainTokenReference: try values.decodeIfPresent(
                String.self, forKey: .keychainTokenReference
            ),
            connectTimeoutSeconds: try values.decodeIfPresent(
                Double.self, forKey: .connectTimeoutSeconds
            ) ?? 5,
            firstByteTimeoutSeconds: try values.decodeIfPresent(
                Double.self, forKey: .firstByteTimeoutSeconds
            ) ?? 15,
            idleTimeoutSeconds: try values.decodeIfPresent(
                Double.self, forKey: .idleTimeoutSeconds
            ) ?? 30,
            totalTimeoutSeconds: try values.decodeIfPresent(
                Double.self, forKey: .totalTimeoutSeconds
            ) ?? 120,
            maximumJSONBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumJSONBytes
            ) ?? 1024 * 1024,
            maximumRequestBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumRequestBytes
            ) ?? 512 * 1024,
            maximumSSELineBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumSSELineBytes
            ) ?? 64 * 1024,
            maximumSSEEventBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumSSEEventBytes
            ) ?? 256 * 1024,
            maximumResponseBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumResponseBytes
            ) ?? 2 * 1024 * 1024,
            maximumTextBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumTextBytes
            ) ?? 512 * 1024,
            maximumToolArgumentBytes: try values.decodeIfPresent(
                Int.self, forKey: .maximumToolArgumentBytes
            ) ?? 256 * 1024,
            maximumOutputTokens: try values.decodeIfPresent(
                Int.self, forKey: .maximumOutputTokens
            ) ?? 4_096
        )
        revision = try values.decodeIfPresent(String.self, forKey: .revision) ?? "0"
    }

    public func validated() throws -> LMStudioProviderConfiguration {
        guard revision == "0" || UUID(uuidString: revision) != nil else {
            throw LMStudioProviderError.invalidConfiguration("configuration revision is invalid")
        }
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = baseURL.host?.lowercased(), !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw LMStudioProviderError.invalidConfiguration("base URL must be an HTTP origin without credentials or query data")
        }
        let loopback = host == "localhost" || host == "127.0.0.1"
            || host == "::1" || host == "[::1]"
        guard scheme == "https" || loopback else {
            throw LMStudioProviderError.invalidConfiguration("non-loopback providers require HTTPS")
        }
        guard baseURL.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw LMStudioProviderError.invalidConfiguration("base URL port is outside supported bounds")
        }
        guard baseURL.path.isEmpty || baseURL.path == "/" else {
            throw LMStudioProviderError.invalidConfiguration("base URL must not include an API path")
        }
        if let modelKey {
            try Self.validateBoundedString(modelKey, field: "model_key", maximumBytes: 512)
        }
        if let keychainTokenReference {
            try Self.validateBoundedString(
                keychainTokenReference,
                field: "keychain_token_reference",
                maximumBytes: 512
            )
        }
        let deadlines = [connectTimeoutSeconds, firstByteTimeoutSeconds, idleTimeoutSeconds, totalTimeoutSeconds]
        guard deadlines.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 600 }),
              totalTimeoutSeconds >= firstByteTimeoutSeconds else {
            throw LMStudioProviderError.invalidConfiguration("deadlines must be positive, bounded, and internally consistent")
        }
        let limits = [
            maximumJSONBytes, maximumRequestBytes, maximumSSELineBytes, maximumSSEEventBytes,
            maximumResponseBytes, maximumTextBytes, maximumToolArgumentBytes,
        ]
        guard limits.allSatisfy({ $0 >= 1024 && $0 <= 16 * 1024 * 1024 }),
              maximumSSELineBytes <= maximumSSEEventBytes,
              maximumSSEEventBytes <= maximumResponseBytes,
              maximumTextBytes <= maximumResponseBytes,
              maximumToolArgumentBytes <= maximumResponseBytes else {
            throw LMStudioProviderError.invalidConfiguration("payload limits are outside supported bounds")
        }
        guard (1...4_096).contains(maximumOutputTokens) else {
            throw LMStudioProviderError.invalidConfiguration(
                "maximum output tokens are outside supported bounds"
            )
        }
        return self
    }

    public func endpoint(_ path: String) throws -> URL {
        let checked = try validated()
        return checked.baseURL.appendingPathComponent(path)
    }

    public static func loadIfPresent(in storageDirectory: URL) throws -> LMStudioProviderConfiguration? {
        let url = storageDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0, byteCount.intValue <= maximumFileBytes else {
            throw LMStudioProviderError.invalidConfiguration("configuration file is empty or oversized")
        }
        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(from: url, maximumBytes: maximumFileBytes)
        } catch {
            throw LMStudioProviderError.invalidConfiguration(
                "configuration file could not be read safely"
            )
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as LMStudioProviderError {
            throw error
        } catch {
            throw LMStudioProviderError.invalidConfiguration("configuration file is not valid JSON")
        }
    }

    fileprivate static func validateBoundedString(
        _ value: String, field: String, maximumBytes: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LMStudioProviderError.invalidConfiguration("invalid \(field)")
        }
    }
}

public protocol LMStudioAuthorizationProviding: Sendable {
    func bearerToken() async throws -> String?
}

public struct LMStudioNoAuthorization: LMStudioAuthorizationProviding {
    public init() {}
    public func bearerToken() async throws -> String? { nil }
}

/// Resolves an LM Studio bearer token from a generic-password Keychain item.
/// Configuration persists only the opaque account reference; token bytes are fetched for each
/// request and are never included in an error, ledger, or diagnostic value.
public struct LMStudioKeychainAuthorization: LMStudioAuthorizationProviding {
    public static let service = "com.forge-conductor.lmstudio"
    public typealias Lookup = @Sendable (_ reference: String) throws -> Data?

    private let reference: String
    private let lookup: Lookup

    public init(reference: String) throws {
        try self.init(reference: reference) { value in
            try LMStudioKeychainAuthorization.systemLookup(reference: value)
        }
    }

    public init(reference: String, lookup: @escaping Lookup) throws {
        try LMStudioProviderConfiguration.validateBoundedString(
            reference, field: "keychain_token_reference", maximumBytes: 512
        )
        self.reference = reference
        self.lookup = lookup
    }

    public func bearerToken() async throws -> String? {
        let data: Data
        do {
            guard let resolved = try lookup(reference), !resolved.isEmpty else {
                throw LMStudioProviderError.invalidConfiguration(
                    "configured Keychain credential is unavailable"
                )
            }
            data = resolved
        } catch let error as LMStudioProviderError {
            throw error
        } catch {
            throw LMStudioProviderError.invalidConfiguration(
                "configured Keychain credential could not be accessed"
            )
        }
        guard data.count <= 8192,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty,
              !token.contains("\n"), !token.contains("\r") else {
            throw LMStudioProviderError.invalidConfiguration(
                "configured Keychain credential is invalid"
            )
        }
        return token
    }

    private static func systemLookup(reference: String) throws -> Data? {
        #if canImport(Security)
        var query = LMStudioKeychainCredentialStore.query(reference)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw LMStudioProviderError.invalidConfiguration(
                "configured Keychain credential could not be accessed"
            )
        }
        #else
        throw LMStudioProviderError.invalidConfiguration(
            "Keychain credentials are unavailable on this platform"
        )
        #endif
    }
}

public enum LMStudioJSONValue: Codable, Sendable, Equatable {
    case object([String: LMStudioJSONValue])
    case array([LMStudioJSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LMStudioJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([LMStudioJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct LMStudioFunctionTool: Encodable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: LMStudioJSONValue
    public var strict: Bool

    public init(
        name: String, description: String, parameters: LMStudioJSONValue, strict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    private enum CodingKeys: String, CodingKey { case type, name, description, parameters, strict }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(strict, forKey: .strict)
    }
}

public enum LMStudioResponseInput: Sendable, Equatable {
    case message(role: String, text: String)
    case functionCallOutput(callID: String, output: String)
}

public struct LMStudioRootRequest: Sendable, Equatable {
    public var operationID: String?
    public var providerRequestID: String?
    public var modelKey: String?
    public var systemPrompt: String
    public var userInput: String
    public var tools: [LMStudioFunctionTool]
    public var idempotencyKey: String

    public init(
        operationID: String? = nil, providerRequestID: String? = nil,
        modelKey: String? = nil,
        systemPrompt: String, userInput: String,
        tools: [LMStudioFunctionTool], idempotencyKey: String
    ) {
        self.operationID = operationID
        self.providerRequestID = providerRequestID
        self.modelKey = modelKey
        self.systemPrompt = systemPrompt
        self.userInput = userInput
        self.tools = tools
        self.idempotencyKey = idempotencyKey
    }
}

public struct LMStudioContinuationRequest: Sendable, Equatable {
    public var operationID: String?
    public var modelKey: String?
    public var previousResponseID: String
    public var input: [LMStudioResponseInput]
    public var tools: [LMStudioFunctionTool]
    public var idempotencyKey: String

    public init(
        operationID: String? = nil, modelKey: String? = nil, previousResponseID: String,
        input: [LMStudioResponseInput], tools: [LMStudioFunctionTool] = [],
        idempotencyKey: String
    ) {
        self.operationID = operationID
        self.modelKey = modelKey
        self.previousResponseID = previousResponseID
        self.input = input
        self.tools = tools
        self.idempotencyKey = idempotencyKey
    }
}

public struct LMStudioLoadedInstance: Codable, Sendable, Equatable {
    public struct Configuration: Codable, Sendable, Equatable {
        public var contextLength: Int
        public var parallel: Int?
        public var flashAttention: Bool?

        private enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case parallel
            case flashAttention = "flash_attention"
        }
    }

    public var id: String
    public var config: Configuration
}

public struct LMStudioModel: Codable, Sendable, Equatable {
    public struct Capabilities: Codable, Sendable, Equatable {
        public var trainedForToolUse: Bool?
        private enum CodingKeys: String, CodingKey { case trainedForToolUse = "trained_for_tool_use" }
    }

    public var key: String
    public var displayName: String?
    public var loadedInstances: [LMStudioLoadedInstance]
    public var maxContextLength: Int?
    public var capabilities: Capabilities?

    private enum CodingKeys: String, CodingKey {
        case key
        case displayName = "display_name"
        case loadedInstances = "loaded_instances"
        case maxContextLength = "max_context_length"
        case capabilities
    }
}

public struct LMStudioProviderCapabilities: Sendable, Equatable {
    public var providerVersion: String
    public var modelKey: String
    public var loadedInstanceID: String
    public var contextLength: Int
    public var maximumContextLength: Int?
    public var parallelism: Int
    public var flashAttention: Bool?
    public var trainedForToolUse: Bool
    public var streamingVerified: Bool
    public var functionToolContractVerified: Bool
    public var usageReportingVerified: Bool
    public var capabilityFingerprintSHA256: String
    public var contractProbeResponseID: String?

    public init(
        providerVersion: String = "unreported",
        modelKey: String, loadedInstanceID: String, contextLength: Int,
        maximumContextLength: Int?, parallelism: Int, flashAttention: Bool?,
        trainedForToolUse: Bool,
        streamingVerified: Bool = false,
        functionToolContractVerified: Bool = false,
        usageReportingVerified: Bool = false,
        capabilityFingerprintSHA256: String = "",
        contractProbeResponseID: String? = nil
    ) {
        self.providerVersion = providerVersion
        self.modelKey = modelKey
        self.loadedInstanceID = loadedInstanceID
        self.contextLength = contextLength
        self.maximumContextLength = maximumContextLength
        self.parallelism = parallelism
        self.flashAttention = flashAttention
        self.trainedForToolUse = trainedForToolUse
        self.streamingVerified = streamingVerified
        self.functionToolContractVerified = functionToolContractVerified
        self.usageReportingVerified = usageReportingVerified
        self.capabilityFingerprintSHA256 = capabilityFingerprintSHA256
        self.contractProbeResponseID = contractProbeResponseID
    }
}

public struct LMStudioUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct LMStudioFunctionCall: Sendable, Equatable {
    public var itemID: String
    public var callID: String
    public var name: String
    public var arguments: String

    public init(itemID: String, callID: String, name: String, arguments: String) {
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct LMStudioResponseTurn: Sendable, Equatable {
    public var responseID: String
    public var previousResponseID: String?
    public var model: String
    public var status: String
    public var assistantText: String
    public var functionCalls: [LMStudioFunctionCall]
    public var usage: LMStudioUsage
    public var usageWasReported: Bool

    public init(
        responseID: String, previousResponseID: String?, model: String,
        status: String, assistantText: String,
        functionCalls: [LMStudioFunctionCall], usage: LMStudioUsage,
        usageWasReported: Bool = true
    ) {
        self.responseID = responseID
        self.previousResponseID = previousResponseID
        self.model = model
        self.status = status
        self.assistantText = assistantText
        self.functionCalls = functionCalls
        self.usage = usage
        self.usageWasReported = usageWasReported
    }
}

public struct LMStudioSSEFrame: Sendable, Equatable {
    public var event: String?
    public var data: Data
    public var isDone: Bool
}

public struct LMStudioSSEDecoder: Sendable {
    public static let maximumEvents = 4096

    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private let maximumTotalBytes: Int
    private var lineBuffer = Data()
    private var eventName: String?
    private var eventData = Data()
    private var totalBytes = 0
    private var emittedEvents = 0

    public init(maximumLineBytes: Int, maximumEventBytes: Int, maximumTotalBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventBytes = maximumEventBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public mutating func feed(_ chunk: Data) throws -> [LMStudioSSEFrame] {
        guard totalBytes + chunk.count <= maximumTotalBytes else {
            throw LMStudioProviderError.limitExceeded("total streaming response")
        }
        totalBytes += chunk.count
        lineBuffer.append(chunk)
        var frames: [LMStudioSSEFrame] = []
        while let newline = lineBuffer.firstIndex(of: 0x0a) {
            var line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if line.last == 0x0d { line.removeLast() }
            guard line.count <= maximumLineBytes else {
                throw LMStudioProviderError.limitExceeded("SSE line")
            }
            if let frame = try consume(line: line) { frames.append(frame) }
        }
        guard lineBuffer.count <= maximumLineBytes else {
            throw LMStudioProviderError.limitExceeded("SSE line")
        }
        return frames
    }

    public mutating func finish() throws -> [LMStudioSSEFrame] {
        var frames: [LMStudioSSEFrame] = []
        if !lineBuffer.isEmpty {
            var line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: false)
            if line.last == 0x0d { line.removeLast() }
            if let frame = try consume(line: line) { frames.append(frame) }
        }
        if !eventData.isEmpty, let frame = try emit() { frames.append(frame) }
        return frames
    }

    private mutating func consume(line: Data) throws -> LMStudioSSEFrame? {
        if line.isEmpty { return try emit() }
        if line.first == 0x3a { return nil }
        let colon = line.firstIndex(of: 0x3a)
        let fieldData = colon.map { line.prefix(upTo: $0) } ?? line[...]
        guard let field = String(data: fieldData, encoding: .utf8) else {
            throw LMStudioProviderError.malformedResponse("SSE field is not UTF-8")
        }
        var valueData = colon.map { line.suffix(from: line.index(after: $0)) } ?? Data.SubSequence()
        if valueData.first == 0x20 { valueData = valueData.dropFirst() }
        switch field {
        case "event":
            guard let value = String(data: valueData, encoding: .utf8), value.utf8.count <= 256 else {
                throw LMStudioProviderError.malformedResponse("SSE event name is invalid")
            }
            eventName = value
        case "data":
            let separatorBytes = eventData.isEmpty ? 0 : 1
            guard eventData.count + separatorBytes + valueData.count <= maximumEventBytes else {
                throw LMStudioProviderError.limitExceeded("SSE event")
            }
            if !eventData.isEmpty { eventData.append(0x0a) }
            eventData.append(contentsOf: valueData)
        default:
            break
        }
        return nil
    }

    private mutating func emit() throws -> LMStudioSSEFrame? {
        guard !eventData.isEmpty else {
            eventName = nil
            return nil
        }
        emittedEvents += 1
        guard emittedEvents <= Self.maximumEvents else {
            throw LMStudioProviderError.limitExceeded("SSE event count")
        }
        let payload = eventData
        let name = eventName
        eventData.removeAll(keepingCapacity: true)
        eventName = nil
        return LMStudioSSEFrame(event: name, data: payload, isDone: payload == Data("[DONE]".utf8))
    }
}

public enum LMStudioProviderIdentifier {
    public static func validate(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw LMStudioProviderError.malformedResponse("provider response identifier is invalid")
        }
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("native-"), !lowered.hasPrefix("forge-logical-session") else {
            throw LMStudioProviderError.syntheticProviderIdentifier
        }
    }
}

public enum LMStudioRedaction {
    private static let patterns = [
        #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"(?i)(^|[^A-Za-z0-9_])["']?(api[_-]?key|access[_-]?token|token|secret|password)["']?\s*[:=]\s*["']?[^\s,;}"']+"#,
    ]

    public static func containsSecretLikeContent(_ value: String) -> Bool {
        patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.firstMatch(in: value, options: [], range: range) != nil
        }
    }

    public static func redact(_ value: String) -> String {
        var result = value
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "[REDACTED]"
            )
        }
        return String(result.prefix(1024))
    }
}

public enum LMStudioHTTPErrorClassifier {
    public static func classify(
        status: Int, retryAfter: String? = nil, body: Data? = nil
    ) -> LMStudioProviderError {
        if let body, let providerSignal = LMStudioProviderSignalClassifier.classify(body) {
            return providerSignal
        }
        return switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .endpointNotFound
        case 409: .conflict
        case 429:
            .rateLimited(retryNanoseconds: retryDelay(retryAfter))
        case 500...599: .serverFailure(status: status)
        default: .malformedResponse("unexpected HTTP status \(status)")
        }
    }

    private static func retryDelay(_ value: String?) -> UInt64? {
        guard let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64(min(seconds, 60) * 1_000_000_000)
    }
}

public enum LMStudioProviderSignalClassifier {
    public static func classify(_ data: Data) -> LMStudioProviderError? {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return classify(text)
    }

    public static func classify(_ value: String) -> LMStudioProviderError? {
        let normalized = value.lowercased()
        let overflowSignals = [
            "context_length_exceeded", "context window exceeded", "context limit exceeded",
            "maximum context length", "context overflow", "too many tokens",
        ]
        if overflowSignals.contains(where: normalized.contains) {
            return .contextOverflow
        }
        let truncationSignals = [
            "response_truncated", "response truncated", "truncation", "truncated",
            "max_output_tokens",
        ]
        if truncationSignals.contains(where: normalized.contains) {
            return .responseTruncated
        }
        return nil
    }
}

private struct LMStudioResponseAccumulator {
    private struct CallBuilder {
        var itemID: String
        var callID: String
        var name: String
        var arguments = Data()
        var completedArguments: String?
    }

    private let maximumTextBytes: Int
    private let maximumToolArgumentBytes: Int
    private var responseID: String?
    private var previousResponseID: String?
    private var model: String?
    private var status: String?
    private var assistantText = Data()
    private var calls: [String: CallBuilder] = [:]
    private var callOrder: [String] = []
    private var usage = LMStudioUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
    private var usageWasReported = false
    private var terminalSeen = false
    private var lastSequence = -1

    init(maximumTextBytes: Int, maximumToolArgumentBytes: Int) {
        self.maximumTextBytes = maximumTextBytes
        self.maximumToolArgumentBytes = maximumToolArgumentBytes
    }

    mutating func consume(_ frame: LMStudioSSEFrame) throws {
        if frame.isDone { return }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: frame.data)
        } catch {
            throw LMStudioProviderError.malformedResponse(
                "SSE data is not a typed JSON event"
            )
        }
        guard let object = decoded as? [String: Any],
              let type = object["type"] as? String else {
            throw LMStudioProviderError.malformedResponse("SSE data is not a typed JSON event")
        }
        if let sequence = object["sequence_number"] as? Int {
            guard sequence > lastSequence else {
                throw LMStudioProviderError.malformedResponse("SSE sequence is not increasing")
            }
            lastSequence = sequence
        }
        switch type {
        case "response.created":
            try captureResponse(object["response"])
        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" else {
                return
            }
            try registerCall(item)
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw LMStudioProviderError.malformedResponse("text delta is missing")
            }
            try append(delta, to: &assistantText, limit: maximumTextBytes, field: "assistant text")
        case "response.function_call_arguments.delta":
            guard let itemID = object["item_id"] as? String,
                  let delta = object["delta"] as? String,
                  var call = calls[itemID] else {
                throw LMStudioProviderError.malformedResponse("function argument delta has no call")
            }
            try append(delta, to: &call.arguments, limit: maximumToolArgumentBytes, field: "tool arguments")
            calls[itemID] = call
        case "response.function_call_arguments.done":
            guard let itemID = object["item_id"] as? String,
                  let arguments = object["arguments"] as? String,
                  var call = calls[itemID] else {
                throw LMStudioProviderError.malformedResponse("completed function arguments have no call")
            }
            guard arguments.utf8.count <= maximumToolArgumentBytes else {
                throw LMStudioProviderError.limitExceeded("tool arguments")
            }
            if !call.arguments.isEmpty,
               String(data: call.arguments, encoding: .utf8) != arguments {
                throw LMStudioProviderError.malformedResponse("function argument deltas do not match completion")
            }
            call.completedArguments = arguments
            if let name = object["name"] as? String, name != call.name {
                throw LMStudioProviderError.malformedResponse("function name changed during streaming")
            }
            calls[itemID] = call
        case "response.completed":
            try captureCompletedResponse(object["response"])
        case "response.incomplete", "response.failed":
            if let response = object["response"],
               JSONSerialization.isValidJSONObject(response),
               let data = try? JSONSerialization.data(withJSONObject: response),
               let signal = LMStudioProviderSignalClassifier.classify(data) {
                throw signal
            }
            throw LMStudioProviderError.malformedResponse(
                "provider response ended without a completed result"
            )
        default:
            break
        }
    }

    mutating func completedTurn() throws -> LMStudioResponseTurn {
        guard terminalSeen, let responseID, let model, let status, status == "completed" else {
            throw LMStudioProviderError.malformedResponse("stream ended without a completed response")
        }
        try LMStudioProviderIdentifier.validate(responseID)
        let normalizedCalls = try callOrder.map { itemID -> LMStudioFunctionCall in
            guard let call = calls[itemID], let arguments = call.completedArguments else {
                throw LMStudioProviderError.malformedResponse("function call did not complete")
            }
            return LMStudioFunctionCall(
                itemID: call.itemID, callID: call.callID, name: call.name, arguments: arguments
            )
        }
        guard let text = String(data: assistantText, encoding: .utf8) else {
            throw LMStudioProviderError.malformedResponse("assistant text is not UTF-8")
        }
        return LMStudioResponseTurn(
            responseID: responseID, previousResponseID: previousResponseID,
            model: model, status: status, assistantText: text,
            functionCalls: normalizedCalls, usage: usage,
            usageWasReported: usageWasReported
        )
    }

    private mutating func captureResponse(_ raw: Any?) throws {
        guard let response = raw as? [String: Any],
              let id = response["id"] as? String,
              let model = response["model"] as? String else {
            throw LMStudioProviderError.malformedResponse("response metadata is incomplete")
        }
        try LMStudioProviderIdentifier.validate(id)
        if let responseID, responseID != id {
            throw LMStudioProviderError.malformedResponse("response identifier changed during streaming")
        }
        self.responseID = id
        self.model = model
        previousResponseID = response["previous_response_id"] as? String
    }

    private mutating func captureCompletedResponse(_ raw: Any?) throws {
        try captureResponse(raw)
        guard let response = raw as? [String: Any], let status = response["status"] as? String else {
            throw LMStudioProviderError.malformedResponse("completed response status is missing")
        }
        if status != "completed",
           let data = try? JSONSerialization.data(withJSONObject: response),
           let signal = LMStudioProviderSignalClassifier.classify(data) {
            throw signal
        }
        self.status = status
        if let values = response["usage"] as? [String: Any] {
            let input = values["input_tokens"] as? Int ?? 0
            let output = values["output_tokens"] as? Int ?? 0
            let total = values["total_tokens"] as? Int ?? input + output
            guard input >= 0, output >= 0, total >= 0, total >= input, total >= output else {
                throw LMStudioProviderError.malformedResponse("response usage is invalid")
            }
            usage = LMStudioUsage(inputTokens: input, outputTokens: output, totalTokens: total)
            usageWasReported = true
        }
        if let output = response["output"] as? [[String: Any]] {
            for item in output where item["type"] as? String == "function_call" {
                try reconcileCompletedCall(item)
            }
            var completedText = Data()
            for item in output where item["type"] as? String == "message" {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content where part["type"] as? String == "output_text" {
                    guard let text = part["text"] as? String else {
                        throw LMStudioProviderError.malformedResponse("completed assistant text is missing")
                    }
                    try append(
                        text, to: &completedText, limit: maximumTextBytes,
                        field: "assistant text"
                    )
                }
            }
            if assistantText.isEmpty {
                assistantText = completedText
            } else if !completedText.isEmpty, assistantText != completedText {
                throw LMStudioProviderError.malformedResponse(
                    "assistant text deltas do not match completion"
                )
            }
        }
        terminalSeen = true
    }

    private mutating func registerCall(_ item: [String: Any]) throws {
        guard callOrder.count < 128 else {
            throw LMStudioProviderError.limitExceeded("function call count")
        }
        guard let itemID = item["id"] as? String,
              let callID = item["call_id"] as? String,
              let name = item["name"] as? String else {
            throw LMStudioProviderError.malformedResponse("function call identity is incomplete")
        }
        try validateIdentifier(itemID, field: "function item")
        try validateIdentifier(callID, field: "function call")
        try validateIdentifier(name, field: "function name")
        guard calls[itemID] == nil else {
            throw LMStudioProviderError.malformedResponse("duplicate function call item")
        }
        calls[itemID] = CallBuilder(itemID: itemID, callID: callID, name: name)
        callOrder.append(itemID)
    }

    private mutating func reconcileCompletedCall(_ item: [String: Any]) throws {
        guard let itemID = item["id"] as? String,
              let callID = item["call_id"] as? String,
              let name = item["name"] as? String,
              let arguments = item["arguments"] as? String else {
            throw LMStudioProviderError.malformedResponse("completed function call is incomplete")
        }
        if calls[itemID] == nil { try registerCall(item) }
        guard var call = calls[itemID], call.callID == callID, call.name == name,
              arguments.utf8.count <= maximumToolArgumentBytes else {
            throw LMStudioProviderError.malformedResponse("completed function call does not match stream")
        }
        if let completed = call.completedArguments, completed != arguments {
            throw LMStudioProviderError.malformedResponse("completed function arguments changed")
        }
        call.completedArguments = arguments
        calls[itemID] = call
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw LMStudioProviderError.malformedResponse("\(field) identifier is invalid")
        }
    }

    private func append(_ value: String, to data: inout Data, limit: Int, field: String) throws {
        let bytes = Data(value.utf8)
        guard data.count + bytes.count <= limit else {
            throw LMStudioProviderError.limitExceeded(field)
        }
        data.append(bytes)
    }
}

private enum LMStudioHTTPResponse {
    case data(Data, HTTPURLResponse)
    case turn(LMStudioResponseTurn, HTTPURLResponse)
}

private enum LMStudioHTTPMode {
    case data(maximumBytes: Int)
    case sse(decoder: LMStudioSSEDecoder, accumulator: LMStudioResponseAccumulator)
}

private final class LMStudioBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let providerConfiguration: LMStudioProviderConfiguration
    private let timeoutQueue = DispatchQueue(label: "forge.lmstudio.request-timeouts")
    private var mode: LMStudioHTTPMode
    private var response: HTTPURLResponse?
    private var body = Data()
    private var errorBody = Data()
    private var continuation: CheckedContinuation<LMStudioHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var connectTimer: DispatchSourceTimer?
    private var byteTimer: DispatchSourceTimer?
    private var totalTimer: DispatchSourceTimer?
    private var completed = false
    private var explicitlyCancelled = false
    private var receivedFirstByte = false

    init(
        configuration: URLSessionConfiguration,
        providerConfiguration: LMStudioProviderConfiguration,
        mode: LMStudioHTTPMode
    ) {
        self.configuration = configuration
        self.providerConfiguration = providerConfiguration
        self.mode = mode
    }

    func run(_ request: URLRequest) async throws -> LMStudioHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        explicitlyCancelled = true
        lock.unlock()
        resolve(.failure(LMStudioProviderError.cancelled))
    }

    private func start(
        _ request: URLRequest,
        continuation: CheckedContinuation<LMStudioHTTPResponse, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: LMStudioProviderError.cancelled)
            return
        }
        self.continuation = continuation
        let delegateQueue = OperationQueue()
        delegateQueue.name = "forge.lmstudio.request-delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration, delegate: self, delegateQueue: delegateQueue
        )
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        installTimersLocked()
        lock.unlock()
        task.resume()
    }

    private func installTimersLocked() {
        let connectTimer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        connectTimer.schedule(deadline: .now() + providerConfiguration.connectTimeoutSeconds)
        connectTimer.setEventHandler { [weak self] in self?.connectDeadlineFired() }
        connectTimer.resume()
        self.connectTimer = connectTimer

        let totalTimer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        totalTimer.schedule(deadline: .now() + providerConfiguration.totalTimeoutSeconds)
        totalTimer.setEventHandler { [weak self] in
            self?.resolve(.failure(LMStudioProviderError.deadlineExceeded(phase: "total")))
        }
        totalTimer.resume()
        self.totalTimer = totalTimer
    }

    private func installByteTimerLocked(after seconds: Double) {
        let byteTimer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        byteTimer.schedule(deadline: .now() + seconds)
        byteTimer.setEventHandler { [weak self] in self?.byteDeadlineFired() }
        byteTimer.resume()
        self.byteTimer = byteTimer
    }

    private func connectDeadlineFired() {
        lock.lock()
        let isWaitingForResponse = response == nil && !completed
        lock.unlock()
        if isWaitingForResponse {
            resolve(.failure(LMStudioProviderError.deadlineExceeded(phase: "connect")))
        }
    }

    private func byteDeadlineFired() {
        lock.lock()
        let phase = receivedFirstByte ? "idle" : "first-byte"
        lock.unlock()
        resolve(.failure(LMStudioProviderError.deadlineExceeded(phase: phase)))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            resolve(.failure(LMStudioProviderError.malformedResponse("HTTP response metadata is missing")))
            return
        }
        lock.lock()
        if completed {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = response
        let connectTimer = self.connectTimer
        self.connectTimer = nil
        installByteTimerLocked(after: providerConfiguration.firstByteTimeoutSeconds)
        lock.unlock()
        connectTimer?.cancel()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var failure: Error?
        lock.lock()
        guard !completed else { lock.unlock(); return }
        receivedFirstByte = true
        byteTimer?.schedule(deadline: .now() + providerConfiguration.idleTimeoutSeconds)
        do {
            if let status = response?.statusCode, !(200...299).contains(status) {
                let remaining = max(0, 64 * 1024 - errorBody.count)
                if data.count > remaining {
                    throw LMStudioProviderError.limitExceeded("HTTP error body")
                }
                errorBody.append(data)
            } else {
                switch mode {
                case .data(let maximumBytes):
                    guard body.count + data.count <= maximumBytes else {
                        throw LMStudioProviderError.limitExceeded("JSON response")
                    }
                    body.append(data)
                case .sse(var decoder, var accumulator):
                    for frame in try decoder.feed(data) { try accumulator.consume(frame) }
                    mode = .sse(decoder: decoder, accumulator: accumulator)
                }
            }
        } catch {
            failure = error
        }
        lock.unlock()
        if let failure { resolve(.failure(failure)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            let cancelled = explicitlyCancelled
            lock.unlock()
            if cancelled { resolve(.failure(LMStudioProviderError.cancelled)) }
            else if let urlError = error as? URLError, urlError.code == .timedOut {
                resolve(.failure(LMStudioProviderError.deadlineExceeded(phase: "connect-or-request")))
            } else if let urlError = error as? URLError, urlError.code == .cancelled {
                resolve(.failure(LMStudioProviderError.cancelled))
            } else {
                resolve(.failure(LMStudioProviderError.providerUnavailable))
            }
            return
        }

        let result: Result<LMStudioHTTPResponse, Error>
        lock.lock()
        do {
            guard let response else {
                throw LMStudioProviderError.malformedResponse("HTTP response is missing")
            }
            guard (200...299).contains(response.statusCode) else {
                throw LMStudioHTTPErrorClassifier.classify(
                    status: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                    body: errorBody
                )
            }
            switch mode {
            case .data:
                result = .success(.data(body, response))
            case .sse(var decoder, var accumulator):
                for frame in try decoder.finish() { try accumulator.consume(frame) }
                result = .success(.turn(try accumulator.completedTurn(), response))
            }
        } catch {
            result = .failure(error)
        }
        lock.unlock()
        resolve(result)
    }

    private func resolve(_ result: Result<LMStudioHTTPResponse, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        let connectTimer = self.connectTimer
        let byteTimer = self.byteTimer
        let totalTimer = self.totalTimer
        self.connectTimer = nil
        self.byteTimer = nil
        self.totalTimer = nil
        lock.unlock()

        connectTimer?.cancel()
        byteTimer?.cancel()
        totalTimer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

private struct LMStudioModelsEnvelope: Decodable {
    var models: [LMStudioModel]
}

private struct LMStudioModelInventory {
    var models: [LMStudioModel]
    var providerVersion: String
}

private enum LMStudioEncodedInput: Encodable {
    case message(role: String, text: String)
    case functionCallOutput(callID: String, output: String)

    private enum CodingKeys: String, CodingKey { case type, role, content, callID = "call_id", output }
    private struct Content: Encodable {
        var type = "input_text"
        var text: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let text):
            try container.encode(role, forKey: .role)
            try container.encode([Content(text: text)], forKey: .content)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }
}

private struct LMStudioResponsesPayload: Encodable {
    var model: String
    var store = true
    var stream = true
    var maximumOutputTokens: Int
    var previousResponseID: String?
    var input: [LMStudioEncodedInput]
    var tools: [LMStudioFunctionTool]

    private enum CodingKeys: String, CodingKey {
        case model, store, stream
        case maximumOutputTokens = "max_output_tokens"
        case previousResponseID = "previous_response_id"
        case input, tools
    }
}

public actor LMStudioRESTClient {
    public static let capabilityCacheSeconds: Double = 15
    public static let capabilityProbeToolName = "forge_provider_contract_probe"

    private let configuration: LMStudioProviderConfiguration
    private let sessionConfiguration: URLSessionConfiguration
    private let authorization: any LMStudioAuthorizationProviding
    private var cachedCapabilities: (
        value: LMStudioProviderCapabilities, expiresAt: ContinuousClock.Instant
    )?

    public init(
        configuration: LMStudioProviderConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        authorization: any LMStudioAuthorizationProviding = LMStudioNoAuthorization()
    ) throws {
        let checked = try configuration.validated()
        let networkSafetyTimeout = min(checked.totalTimeoutSeconds + 5, 1_200)
        sessionConfiguration.timeoutIntervalForRequest = networkSafetyTimeout
        sessionConfiguration.timeoutIntervalForResource = networkSafetyTimeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        self.configuration = checked
        self.sessionConfiguration = sessionConfiguration
        self.authorization = authorization
    }

    public func listModels() async throws -> [LMStudioModel] {
        try await modelInventory().models
    }

    private func modelInventory() async throws -> LMStudioModelInventory {
        var request = URLRequest(url: try configuration.endpoint("api/v1/models"))
        request.httpMethod = "GET"
        try await authorize(&request)
        let runner = LMStudioBoundedRequest(
            configuration: sessionConfiguration,
            providerConfiguration: configuration,
            mode: .data(maximumBytes: configuration.maximumJSONBytes)
        )
        guard case .data(let data, let response) = try await runner.run(request) else {
            throw LMStudioProviderError.malformedResponse("model response used the wrong transport")
        }
        do {
            let envelope = try JSONDecoder().decode(LMStudioModelsEnvelope.self, from: data)
            guard envelope.models.count <= 512 else {
                throw LMStudioProviderError.limitExceeded("model count")
            }
            return LMStudioModelInventory(
                models: envelope.models,
                providerVersion: providerVersion(from: response)
            )
        } catch let error as LMStudioProviderError {
            throw error
        } catch {
            throw LMStudioProviderError.malformedResponse("model list is not valid JSON")
        }
    }

    public func probe() async throws -> LMStudioProviderCapabilities {
        if let cachedCapabilities, ContinuousClock.now < cachedCapabilities.expiresAt {
            return cachedCapabilities.value
        }
        let inventory = try await modelInventory()
        let candidates = inventory.models.filter {
            !$0.loadedInstances.isEmpty && $0.capabilities?.trainedForToolUse == true
        }
        let selected: LMStudioModel
        if let configured = configuration.modelKey {
            guard let match = inventory.models.first(where: { $0.key == configured }) else {
                throw LMStudioProviderError.invalidConfiguration("configured model was not found; refresh models and select an available identifier")
            }
            guard !match.loadedInstances.isEmpty else {
                throw LMStudioProviderError.invalidConfiguration("configured model is unloaded; load it in LM Studio and retry")
            }
            guard match.capabilities?.trainedForToolUse == true else {
                throw LMStudioProviderError.invalidConfiguration("configured model does not support tool use; select a tool-capable model")
            }
            selected = match
        } else {
            guard !inventory.models.isEmpty else {
                throw LMStudioProviderError.invalidConfiguration("no models are available; add a model in LM Studio")
            }
            guard candidates.count == 1, let only = candidates.first else {
                throw LMStudioProviderError.invalidConfiguration("select exactly one loaded tool-capable model")
            }
            selected = only
        }
        guard let instance = selected.loadedInstances.first,
              instance.config.contextLength > 0,
              (instance.config.parallel ?? 1) > 0,
              selected.maxContextLength.map({ instance.config.contextLength <= $0 }) ?? true else {
            throw LMStudioProviderError.malformedResponse("loaded model configuration is invalid")
        }
        try LMStudioProviderConfiguration.validateBoundedString(
            selected.key, field: "model key", maximumBytes: 512
        )
        try LMStudioProviderConfiguration.validateBoundedString(
            instance.id, field: "loaded instance", maximumBytes: 512
        )
        let probeTool = LMStudioFunctionTool(
            name: Self.capabilityProbeToolName,
            description: "Return the exact non-destructive provider contract probe receipt.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .boolean(false),
                "properties": .object([
                    "contract_version": .object(["const": .integer(1)]),
                    "accepted": .object(["const": .boolean(true)]),
                ]),
                "required": .array([
                    .string("contract_version"), .string("accepted"),
                ]),
            ])
        )
        let contractTurn = try await performResponse(
            model: selected.key,
            previousResponseID: nil,
            input: [
                .message(
                    role: "system",
                    text: "Call forge_provider_contract_probe exactly once with contract_version 1 and accepted true."
                ),
                .message(role: "user", text: "Verify the structured function-tool contract."),
            ],
            tools: [probeTool],
            idempotencyKey: "forge-provider-contract-probe-v1-" + JSONSupport.sha256Hex(
                inventory.providerVersion + "\u{0}" + selected.key + "\u{0}" + instance.id
            ),
            providerRequestID: nil
        )
        guard contractTurn.previousResponseID == nil,
              contractTurn.status == "completed",
              Self.responseModelMatches(
                contractTurn.model,
                modelKey: selected.key,
                loadedInstanceID: instance.id
              ),
              contractTurn.functionCalls.count == 1,
              let call = contractTurn.functionCalls.first,
              call.name == Self.capabilityProbeToolName,
              let arguments = call.arguments.data(using: .utf8),
              arguments.count <= configuration.maximumToolArgumentBytes,
              let acknowledgement = try JSONSerialization.jsonObject(with: arguments)
                as? [String: Any],
              Set(acknowledgement.keys) == Set(["contract_version", "accepted"]),
              acknowledgement["contract_version"] as? Int == 1,
              acknowledgement["accepted"] as? Bool == true else {
            throw LMStudioProviderError.invalidConfiguration(
                "Responses function-tool contract probe failed"
            )
        }
        let fingerprintObject: [String: Any] = [
            "provider": "lmstudio",
            "provider_version": inventory.providerVersion,
            "model_key": selected.key,
            "loaded_instance_id": instance.id,
            "context_length": instance.config.contextLength,
            "maximum_context_length": selected.maxContextLength ?? NSNull(),
            "parallelism": instance.config.parallel ?? 1,
            "flash_attention": instance.config.flashAttention ?? NSNull(),
            "trained_for_tool_use": true,
            "streaming_verified": true,
            "function_tool_contract_verified": true,
            "usage_reporting_verified": contractTurn.usageWasReported,
        ]
        let fingerprintData = try JSONSerialization.data(
            withJSONObject: fingerprintObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let capabilities = LMStudioProviderCapabilities(
            providerVersion: inventory.providerVersion,
            modelKey: selected.key, loadedInstanceID: instance.id,
            contextLength: instance.config.contextLength,
            maximumContextLength: selected.maxContextLength,
            parallelism: instance.config.parallel ?? 1,
            flashAttention: instance.config.flashAttention,
            trainedForToolUse: true,
            streamingVerified: true,
            functionToolContractVerified: true,
            usageReportingVerified: contractTurn.usageWasReported,
            capabilityFingerprintSHA256: JSONSupport.sha256Hex(fingerprintData),
            contractProbeResponseID: contractTurn.responseID
        )
        cachedCapabilities = (
            capabilities,
            ContinuousClock.now.advanced(by: .seconds(Self.capabilityCacheSeconds))
        )
        return capabilities
    }

    /// LM Studio accepts a catalog model key when creating a response, while the
    /// terminal response can identify the exact loaded instance selected for that
    /// request. Both names are bound by the immediately preceding inventory probe;
    /// no third or caller-supplied alias is accepted.
    private static func responseModelMatches(
        _ responseModel: String,
        modelKey: String,
        loadedInstanceID: String
    ) -> Bool {
        responseModel == modelKey || responseModel == loadedInstanceID
    }

    private func providerVersion(from response: HTTPURLResponse) -> String {
        let value = [
            "X-LM-Studio-Version", "LM-Studio-Version", "Server",
        ].compactMap { response.value(forHTTPHeaderField: $0) }.first
            ?? "unreported"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              !trimmed.contains("\n"), !trimmed.contains("\r"),
              !LMStudioRedaction.containsSecretLikeContent(trimmed) else {
            return "unreported"
        }
        return trimmed
    }

    public func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        let model = try await resolvedModel(request.modelKey)
        try validateRequestText(request.userInput, field: "user input")
        var input: [LMStudioEncodedInput] = []
        if !request.systemPrompt.isEmpty {
            try validateRequestText(request.systemPrompt, field: "system prompt")
            input.append(.message(role: "system", text: request.systemPrompt))
        }
        input.append(.message(role: "user", text: request.userInput))
        let turn = try await performResponse(
            model: model, previousResponseID: nil, input: input,
            tools: request.tools, idempotencyKey: request.idempotencyKey,
            providerRequestID: request.providerRequestID
        )
        guard turn.previousResponseID == nil else {
            throw LMStudioProviderError.malformedResponse("fresh root unexpectedly references a predecessor")
        }
        return turn
    }

    public func continueSession(
        _ request: LMStudioContinuationRequest
    ) async throws -> LMStudioResponseTurn {
        try LMStudioProviderIdentifier.validate(request.previousResponseID)
        let model = try await resolvedModel(request.modelKey)
        let input = try request.input.map { value -> LMStudioEncodedInput in
            switch value {
            case .message(let role, let text):
                guard ["system", "user", "assistant"].contains(role) else {
                    throw LMStudioProviderError.invalidConfiguration("continuation message role is invalid")
                }
                try validateRequestText(text, field: "continuation message")
                return .message(role: role, text: text)
            case .functionCallOutput(let callID, let output):
                try LMStudioProviderConfiguration.validateBoundedString(
                    callID, field: "provider call ID", maximumBytes: 512
                )
                try validateRequestText(output, field: "tool output")
                return .functionCallOutput(callID: callID, output: output)
            }
        }
        guard !input.isEmpty, input.count <= 128 else {
            throw LMStudioProviderError.invalidConfiguration("continuation input count is invalid")
        }
        let turn = try await performResponse(
            model: model, previousResponseID: request.previousResponseID,
            input: input, tools: request.tools, idempotencyKey: request.idempotencyKey,
            providerRequestID: nil
        )
        guard turn.previousResponseID == request.previousResponseID else {
            throw LMStudioProviderError.malformedResponse("continuation authority does not match the requested predecessor")
        }
        return turn
    }

    private func resolvedModel(_ requested: String?) async throws -> String {
        let capabilities = try await probe()
        if let requested {
            try LMStudioProviderConfiguration.validateBoundedString(
                requested, field: "model key", maximumBytes: 512
            )
            guard requested == capabilities.modelKey else {
                throw LMStudioProviderError.invalidConfiguration(
                    "request model does not match the probed tool-capable model"
                )
            }
        }
        return capabilities.modelKey
    }

    private func performResponse(
        model: String, previousResponseID: String?, input: [LMStudioEncodedInput],
        tools: [LMStudioFunctionTool], idempotencyKey: String,
        providerRequestID: String?
    ) async throws -> LMStudioResponseTurn {
        guard tools.count <= 128 else {
            throw LMStudioProviderError.invalidConfiguration("tool count exceeds 128")
        }
        for tool in tools {
            try LMStudioProviderConfiguration.validateBoundedString(
                tool.name, field: "tool name", maximumBytes: 128
            )
            guard tool.description.utf8.count <= 4096 else {
                throw LMStudioProviderError.invalidConfiguration("tool description is oversized")
            }
        }
        try LMStudioProviderConfiguration.validateBoundedString(
            idempotencyKey, field: "idempotency key", maximumBytes: 1024
        )
        if let providerRequestID {
            try LMStudioProviderConfiguration.validateBoundedString(
                providerRequestID, field: "provider request ID", maximumBytes: 1024
            )
        }
        let payload = LMStudioResponsesPayload(
            model: model,
            maximumOutputTokens: configuration.maximumOutputTokens,
            previousResponseID: previousResponseID,
            input: input,
            tools: tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        guard body.count <= configuration.maximumRequestBytes else {
            throw LMStudioProviderError.limitExceeded("request body")
        }
        var request = URLRequest(url: try configuration.endpoint("v1/responses"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = min(configuration.totalTimeoutSeconds + 5, 1_200)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(JSONSupport.sha256Hex(idempotencyKey), forHTTPHeaderField: "X-Forge-Operation-Key")
        if let providerRequestID {
            request.setValue(providerRequestID, forHTTPHeaderField: "X-Forge-Request-ID")
        }
        try await authorize(&request)
        let decoder = LMStudioSSEDecoder(
            maximumLineBytes: configuration.maximumSSELineBytes,
            maximumEventBytes: configuration.maximumSSEEventBytes,
            maximumTotalBytes: configuration.maximumResponseBytes
        )
        let accumulator = LMStudioResponseAccumulator(
            maximumTextBytes: configuration.maximumTextBytes,
            maximumToolArgumentBytes: configuration.maximumToolArgumentBytes
        )
        let runner = LMStudioBoundedRequest(
            configuration: sessionConfiguration,
            providerConfiguration: configuration,
            mode: .sse(decoder: decoder, accumulator: accumulator)
        )
        guard case .turn(let turn, let response) = try await runner.run(request) else {
            throw LMStudioProviderError.malformedResponse("Responses endpoint used the wrong transport")
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true else {
            throw LMStudioProviderError.malformedResponse("Responses endpoint did not return an SSE stream")
        }
        return turn
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let token: String?
        do {
            token = try await authorization.bearerToken()
        } catch {
            throw LMStudioProviderError.invalidConfiguration("authorization provider failed")
        }
        guard let token else { return }
        guard !token.isEmpty, token.utf8.count <= 8192,
              !token.contains("\n"), !token.contains("\r") else {
            throw LMStudioProviderError.invalidConfiguration("credential material is invalid")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func validateRequestText(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= configuration.maximumRequestBytes else {
            throw LMStudioProviderError.invalidConfiguration("\(field) is empty or oversized")
        }
    }
}

public protocol LMStudioManagedTransporting: Sendable {
    func probe() async throws -> LMStudioProviderCapabilities
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn?
    func cancel(operationID: String) async
}

public actor LMStudioManagedSessionTransport: LMStudioManagedTransporting {
    public static let maximumInFlightOperations = 16
    public static let maximumReceipts = 32

    public nonisolated let client: LMStudioRESTClient
    private var inFlight: [String: Task<LMStudioResponseTurn, Error>] = [:]
    private var operationToIdempotencyKey: [String: String] = [:]
    private var receipts: [String: LMStudioResponseTurn] = [:]
    private var receiptOrder: [String] = []

    public init(client: LMStudioRESTClient) { self.client = client }

    public init(
        configuration: LMStudioProviderConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        authorization: any LMStudioAuthorizationProviding = LMStudioNoAuthorization()
    ) throws {
        self.client = try LMStudioRESTClient(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            authorization: authorization
        )
    }

    public func probe() async throws -> LMStudioProviderCapabilities {
        try await client.probe()
    }

    public func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        try await execute(
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey
        ) { [client] in
            try await client.createRoot(request)
        }
    }

    public func continueSession(
        _ request: LMStudioContinuationRequest
    ) async throws -> LMStudioResponseTurn {
        try await execute(
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey
        ) { [client] in
            try await client.continueSession(request)
        }
    }

    public func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        receipts[key]
    }

    public func cancel(operationID: String) async {
        let key = operationToIdempotencyKey[operationID] ?? operationID
        inFlight[key]?.cancel()
    }

    private func execute(
        operationID: String?,
        idempotencyKey: String,
        operation: @escaping @Sendable () async throws -> LMStudioResponseTurn
    ) async throws -> LMStudioResponseTurn {
        if let receipt = receipts[idempotencyKey] { return receipt }
        if let task = inFlight[idempotencyKey] { return try await task.value }
        guard inFlight.count < Self.maximumInFlightOperations else {
            throw LMStudioProviderError.limitExceeded("concurrent provider operation")
        }
        let task = Task { try await operation() }
        inFlight[idempotencyKey] = task
        if let operationID { operationToIdempotencyKey[operationID] = idempotencyKey }
        do {
            let turn = try await task.value
            inFlight.removeValue(forKey: idempotencyKey)
            if let operationID { operationToIdempotencyKey.removeValue(forKey: operationID) }
            store(turn, for: idempotencyKey)
            return turn
        } catch {
            inFlight.removeValue(forKey: idempotencyKey)
            if let operationID { operationToIdempotencyKey.removeValue(forKey: operationID) }
            throw error
        }
    }

    private func store(_ turn: LMStudioResponseTurn, for key: String) {
        if receipts[key] == nil { receiptOrder.append(key) }
        receipts[key] = turn
        while receiptOrder.count > Self.maximumReceipts {
            receipts.removeValue(forKey: receiptOrder.removeFirst())
        }
    }
}

private enum LMStudioManagedProviderReceiptStatus: String, Codable {
    case intent
    case accepted
}

private struct LMStudioManagedProviderReceiptRecord: Codable {
    var idempotencyKeySHA256: String
    var requestFingerprintSHA256: String
    var requestID: String
    var capabilities: ProviderCapabilities
    var status: LMStudioManagedProviderReceiptStatus
    var turn: ProviderTurn?
    var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case idempotencyKeySHA256 = "idempotency_key_sha256"
        case requestFingerprintSHA256 = "request_fingerprint_sha256"
        case requestID = "request_id"
        case capabilities, status, turn
        case updatedAt = "updated_at"
    }
}

private struct LMStudioManagedProviderReceiptLedger: Codable {
    var schemaVersion = 1
    var records: [LMStudioManagedProviderReceiptRecord] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }
}

/// A bounded, owner-only receipt store shared by every production provider
/// instance. Accepted turns survive manager replacement. An unfinished intent
/// is leased before it may be retried. Because LM Studio does not expose a
/// request-ID receipt lookup, an expired-intent retry can cause at most one
/// duplicate model inference for that retry attempt; repeated later retries can
/// repeat that cost. Tool execution is reconciled independently by the manager,
/// so this mitigation does not authorize duplicate tool side effects and must
/// not be described as eliminating the provider-response crash race.
private struct LMStudioManagedProviderReceiptStore: Sendable {
    static let fileName = "managed-provider-receipts.json"
    static let maximumRecords = 32
    static let maximumLedgerBytes = 32 * 1_024 * 1_024
    static let intentLeaseSeconds: TimeInterval = 660

    let ledgerURL: URL

    init(storageDirectory: URL) throws {
        ledgerURL = storageDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
        try withLedgerLock {
            _ = try loadLedger()
        }
    }

    func record(
        forIdempotencyKey key: String,
        requestFingerprint: String? = nil
    ) throws -> LMStudioManagedProviderReceiptRecord? {
        let digest = JSONSupport.sha256Hex(key)
        return try withLedgerLock {
            let ledger = try loadLedger()
            guard let record = ledger.records.first(where: {
                $0.idempotencyKeySHA256 == digest
            }) else { return nil }
            if let requestFingerprint,
               record.requestFingerprintSHA256 != requestFingerprint {
                throw LMStudioProviderError.invalidConfiguration(
                    "an idempotency key was reused for a different provider request"
                )
            }
            return record
        }
    }

    /// Claims a new or expired intent. `false` means another instance still
    /// owns a live intent or committed an accepted turn while this caller was
    /// probing provider capabilities.
    func claim(
        idempotencyKey: String,
        requestFingerprint: String,
        requestID: String,
        capabilities: ProviderCapabilities,
        now: Date = Date()
    ) throws -> Bool {
        let digest = JSONSupport.sha256Hex(idempotencyKey)
        return try withLedgerLock {
            var ledger = try loadLedger()
            if let index = ledger.records.firstIndex(where: {
                $0.idempotencyKeySHA256 == digest
            }) {
                let existing = ledger.records[index]
                guard existing.requestFingerprintSHA256 == requestFingerprint else {
                    throw LMStudioProviderError.invalidConfiguration(
                        "an idempotency key was reused for a different provider request"
                    )
                }
                guard existing.status == .intent,
                      Self.intentLeaseExpired(existing, now: now) else {
                    return false
                }
                ledger.records[index].requestID = requestID
                ledger.records[index].capabilities = capabilities
                ledger.records[index].updatedAt = ISO8601.string(from: now)
                try persist(ledger, protecting: digest)
                return true
            }

            while ledger.records.count >= Self.maximumRecords {
                guard let removable = ledger.records.enumerated()
                    .filter({ $0.element.status == .accepted })
                    .min(by: { $0.element.updatedAt < $1.element.updatedAt })?.offset else {
                    throw LMStudioProviderError.limitExceeded(
                        "durable provider receipt record"
                    )
                }
                ledger.records.remove(at: removable)
            }
            ledger.records.append(LMStudioManagedProviderReceiptRecord(
                idempotencyKeySHA256: digest,
                requestFingerprintSHA256: requestFingerprint,
                requestID: requestID,
                capabilities: capabilities,
                status: .intent,
                turn: nil,
                updatedAt: ISO8601.string(from: now)
            ))
            try persist(ledger, protecting: digest)
            return true
        }
    }

    func accept(
        idempotencyKey: String,
        requestFingerprint: String,
        turn: ProviderTurn,
        capabilities: ProviderCapabilities,
        now: Date = Date()
    ) throws {
        let digest = JSONSupport.sha256Hex(idempotencyKey)
        try withLedgerLock {
            var ledger = try loadLedger()
            guard let index = ledger.records.firstIndex(where: {
                $0.idempotencyKeySHA256 == digest
            }) else {
                throw LMStudioProviderError.receiptStorage(
                    "the provider intent disappeared before its terminal receipt was stored"
                )
            }
            guard ledger.records[index].requestFingerprintSHA256 == requestFingerprint else {
                throw LMStudioProviderError.invalidConfiguration(
                    "an idempotency key was reused for a different provider request"
                )
            }
            ledger.records[index].requestID = turn.requestID
            ledger.records[index].capabilities = capabilities
            ledger.records[index].status = .accepted
            ledger.records[index].turn = turn
            ledger.records[index].updatedAt = ISO8601.string(from: now)
            try persist(ledger, protecting: digest)
        }
    }

    func removeRejectedIntent(
        idempotencyKey: String,
        requestFingerprint: String
    ) {
        let digest = JSONSupport.sha256Hex(idempotencyKey)
        try? withLedgerLock {
            var ledger = try loadLedger()
            ledger.records.removeAll {
                $0.idempotencyKeySHA256 == digest
                    && $0.requestFingerprintSHA256 == requestFingerprint
                    && $0.status == .intent
            }
            try persist(ledger, protecting: nil)
        }
    }

    func intentLeaseExpired(
        _ record: LMStudioManagedProviderReceiptRecord,
        now: Date = Date()
    ) -> Bool {
        Self.intentLeaseExpired(record, now: now)
    }

    private static func intentLeaseExpired(
        _ record: LMStudioManagedProviderReceiptRecord,
        now: Date
    ) -> Bool {
        guard record.status == .intent,
              let updated = ISO8601.date(from: record.updatedAt) else { return false }
        return now.timeIntervalSince(updated) >= intentLeaseSeconds
    }

    private func withLedgerLock<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: ledgerURL,
                timeoutSeconds: 10,
                body
            )
        } catch let error as LMStudioProviderError {
            throw error
        } catch {
            throw LMStudioProviderError.receiptStorage(
                String(error.localizedDescription.prefix(2_048))
            )
        }
    }

    private func loadLedger() throws -> LMStudioManagedProviderReceiptLedger {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            return LMStudioManagedProviderReceiptLedger()
        }
        let data = try OwnerOnlyAtomicFile.read(
            from: ledgerURL,
            maximumBytes: Self.maximumLedgerBytes
        )
        let ledger = try JSONDecoder().decode(
            LMStudioManagedProviderReceiptLedger.self,
            from: data
        )
        try Self.validate(ledger, encodedBytes: data.count)
        return ledger
    }

    private func persist(
        _ input: LMStudioManagedProviderReceiptLedger,
        protecting protectedDigest: String?
    ) throws {
        var ledger = input
        var data = try Self.encoded(ledger)
        while data.count > Self.maximumLedgerBytes {
            guard let removable = ledger.records.enumerated()
                .filter({ record in
                    record.element.status == .accepted
                        && record.element.idempotencyKeySHA256 != protectedDigest
                })
                .min(by: { $0.element.updatedAt < $1.element.updatedAt })?.offset else {
                throw LMStudioProviderError.limitExceeded(
                    "durable provider receipt file"
                )
            }
            ledger.records.remove(at: removable)
            data = try Self.encoded(ledger)
        }
        try Self.validate(ledger, encodedBytes: data.count)
        try OwnerOnlyAtomicFile.write(data, to: ledgerURL)
    }

    private static func encoded(_ ledger: LMStudioManagedProviderReceiptLedger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    private static func validate(
        _ ledger: LMStudioManagedProviderReceiptLedger,
        encodedBytes: Int
    ) throws {
        guard ledger.schemaVersion == 1,
              ledger.records.count <= maximumRecords,
              encodedBytes <= maximumLedgerBytes else {
            throw LMStudioProviderError.receiptStorage(
                "the durable provider receipt ledger is unsupported or oversized"
            )
        }
        var digests = Set<String>()
        for record in ledger.records {
            guard Self.isSHA256(record.idempotencyKeySHA256),
                  Self.isSHA256(record.requestFingerprintSHA256),
                  digests.insert(record.idempotencyKeySHA256).inserted,
                  !record.requestID.isEmpty,
                  record.requestID.utf8.count
                    <= ManagedModelProviderContract.maximumIdentifierBytes,
                  ISO8601.date(from: record.updatedAt) != nil else {
                throw LMStudioProviderError.receiptStorage(
                    "the durable provider receipt ledger has invalid record identity"
                )
            }
            let capabilities = try Self.validated(record.capabilities)
            guard capabilities.providerID == "lmstudio" else {
                throw LMStudioProviderError.receiptStorage(
                    "the durable provider receipt has an invalid provider identity"
                )
            }
            switch (record.status, record.turn) {
            case (.intent, nil):
                break
            case (.accepted, .some(let turn)):
                let validatedTurn = try Self.validated(turn)
                guard validatedTurn.requestID == record.requestID,
                      validatedTurn.providerID == "lmstudio" else {
                    throw LMStudioProviderError.receiptStorage(
                        "the durable provider receipt does not match its request"
                    )
                }
            default:
                throw LMStudioProviderError.receiptStorage(
                    "the durable provider receipt has an invalid state"
                )
            }
        }
    }

    private static func validated(_ capabilities: ProviderCapabilities) throws
        -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: capabilities.providerID,
            providerVersion: capabilities.providerVersion,
            modelKey: capabilities.modelKey,
            providerInstanceID: capabilities.providerInstanceID,
            contextLength: capabilities.contextLength,
            maximumContextLength: capabilities.maximumContextLength,
            statefulResponses: capabilities.statefulResponses,
            streaming: capabilities.streaming,
            customTools: capabilities.customTools,
            mcp: capabilities.mcp,
            structuredOutput: capabilities.structuredOutput,
            usageReporting: capabilities.usageReporting,
            idempotencyLookup: capabilities.idempotencyLookup,
            capabilityFingerprintSHA256: capabilities.capabilityFingerprintSHA256
        )
    }

    private static func validated(_ turn: ProviderTurn) throws -> ProviderTurn {
        try ProviderTurn(
            requestID: turn.requestID,
            responseID: turn.responseID,
            previousResponseID: turn.previousResponseID,
            providerID: turn.providerID,
            providerVersion: turn.providerVersion,
            modelKey: turn.modelKey,
            providerInstanceID: turn.providerInstanceID,
            messages: turn.messages,
            toolCalls: turn.toolCalls,
            structuredOutputJSON: turn.structuredOutputJSON,
            usage: turn.usage,
            completed: turn.completed,
            finishReason: turn.finishReason,
            rawArtifactID: turn.rawArtifactID
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

public actor LMStudioManagedModelProvider: ManagedModelProvider {
    public static let maximumRememberedRequestIDs = 32
    public nonisolated let providerID = "lmstudio"

    public nonisolated let transport: any LMStudioManagedTransporting
    private let receiptStore: LMStudioManagedProviderReceiptStore?
    private var latestCapabilities: ProviderCapabilities?
    private var requestIDsByIdempotencyKey: [String: String] = [:]
    private var requestIDOrder: [String] = []

    public init(transport: any LMStudioManagedTransporting) {
        self.transport = transport
        receiptStore = nil
    }

    public init(
        storageDirectory: URL,
        transport: any LMStudioManagedTransporting
    ) throws {
        self.transport = transport
        receiptStore = try LMStudioManagedProviderReceiptStore(
            storageDirectory: storageDirectory
        )
    }

    public func probe() async throws -> ProviderCapabilities {
        let capabilities = try await transport.probe()
        let normalized = try ProviderCapabilities(
            providerID: providerID,
            providerVersion: capabilities.providerVersion,
            modelKey: capabilities.modelKey,
            providerInstanceID: capabilities.loadedInstanceID,
            contextLength: capabilities.contextLength,
            maximumContextLength: capabilities.maximumContextLength,
            statefulResponses: true,
            streaming: capabilities.streamingVerified,
            customTools: capabilities.trainedForToolUse
                && capabilities.functionToolContractVerified,
            mcp: false,
            structuredOutput: false,
            usageReporting: capabilities.usageReportingVerified,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: capabilities.capabilityFingerprintSHA256
        )
        latestCapabilities = normalized
        return normalized
    }

    public func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        let request = try request.validated()
        guard request.structuredOutputSchema == nil else {
            throw ManagedModelProviderContractError.unsupportedCapability(
                "LM Studio structured response format is not enabled by this adapter"
            )
        }
        let requestID = request.operationID.uuidString.lowercased()
        let fingerprint = try Self.requestFingerprint(
            kind: "root",
            operationID: request.operationID,
            modelKey: request.modelKey,
            previousResponseID: nil,
            input: Data(request.input.utf8),
            tools: request.tools
        )
        if let recovered = try await durableReceipt(
            idempotencyKey: request.idempotencyKey,
            requestFingerprint: fingerprint
        ) {
            return recovered
        }
        let capabilities = try await probe()
        guard request.modelKey == capabilities.modelKey else {
            throw ManagedModelProviderContractError.invalidValue(
                "request model does not match the probed model"
            )
        }
        let tools = try request.tools.map(Self.functionTool)
        if let receiptStore {
            let claimed = try receiptStore.claim(
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint,
                requestID: requestID,
                capabilities: capabilities
            )
            if !claimed {
                if let recovered = try await durableReceipt(
                    idempotencyKey: request.idempotencyKey,
                    requestFingerprint: fingerprint
                ) {
                    return recovered
                }
                throw LMStudioProviderError.conflict
            }
        }
        remember(requestID: requestID, forIdempotencyKey: request.idempotencyKey)
        do {
            let turn = try await transport.createRoot(LMStudioRootRequest(
                operationID: requestID,
                providerRequestID: requestID,
                modelKey: request.modelKey,
                systemPrompt: "",
                userInput: request.input,
                tools: tools,
                idempotencyKey: request.idempotencyKey
            ))
            guard turn.previousResponseID == nil else {
                throw ManagedModelProviderContractError.invalidValue(
                    "root response unexpectedly references a predecessor"
                )
            }
            let normalized = try normalize(
                turn,
                requestID: requestID,
                capabilities: capabilities
            )
            try receiptStore?.accept(
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint,
                turn: normalized,
                capabilities: capabilities
            )
            return normalized
        } catch {
            clearRejectedIntentIfDefinitive(
                error,
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint
            )
            throw error
        }
    }

    public func continueSession(
        _ request: ProviderContinuationRequest
    ) async throws -> ProviderTurn {
        let request = try request.validated()
        let requestID = request.operationID.uuidString.lowercased()
        let fingerprint = try Self.requestFingerprint(
            kind: "continuation",
            operationID: request.operationID,
            modelKey: request.modelKey,
            previousResponseID: request.previousResponseID,
            input: request.input,
            tools: request.tools
        )
        if let recovered = try await durableReceipt(
            idempotencyKey: request.idempotencyKey,
            requestFingerprint: fingerprint
        ) {
            return recovered
        }
        let capabilities = try await probe()
        guard request.modelKey == capabilities.modelKey else {
            throw ManagedModelProviderContractError.invalidValue(
                "request model does not match the probed model"
            )
        }
        let input = try Self.continuationInput(request.input)
        let tools = try request.tools.map(Self.functionTool)
        if let receiptStore {
            let claimed = try receiptStore.claim(
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint,
                requestID: requestID,
                capabilities: capabilities
            )
            if !claimed {
                if let recovered = try await durableReceipt(
                    idempotencyKey: request.idempotencyKey,
                    requestFingerprint: fingerprint
                ) {
                    return recovered
                }
                throw LMStudioProviderError.conflict
            }
        }
        remember(requestID: requestID, forIdempotencyKey: request.idempotencyKey)
        do {
            let turn = try await transport.continueSession(LMStudioContinuationRequest(
                operationID: requestID,
                modelKey: request.modelKey,
                previousResponseID: request.previousResponseID,
                input: input,
                tools: tools,
                idempotencyKey: request.idempotencyKey
            ))
            guard turn.previousResponseID == request.previousResponseID else {
                throw ManagedModelProviderContractError.invalidValue(
                    "continuation response does not reference the requested predecessor"
                )
            }
            let normalized = try normalize(
                turn,
                requestID: requestID,
                capabilities: capabilities
            )
            try receiptStore?.accept(
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint,
                turn: normalized,
                capabilities: capabilities
            )
            return normalized
        } catch {
            clearRejectedIntentIfDefinitive(
                error,
                idempotencyKey: request.idempotencyKey,
                requestFingerprint: fingerprint
            )
            throw error
        }
    }

    public func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        try ManagedModelProviderContract.validateIdempotencyKey(idempotencyKey)
        if let record = try receiptStore?.record(forIdempotencyKey: idempotencyKey) {
            latestCapabilities = record.capabilities
            if let turn = record.turn { return turn }
            if let transportTurn = await transport.receipt(
                forIdempotencyKey: idempotencyKey
            ) {
                let normalized = try normalize(
                    transportTurn,
                    requestID: record.requestID,
                    capabilities: record.capabilities
                )
                try receiptStore?.accept(
                    idempotencyKey: idempotencyKey,
                    requestFingerprint: record.requestFingerprintSHA256,
                    turn: normalized,
                    capabilities: record.capabilities
                )
                return normalized
            }
            return nil
        }
        guard let turn = await transport.receipt(forIdempotencyKey: idempotencyKey) else {
            return nil
        }
        let capabilities: ProviderCapabilities
        if let latestCapabilities {
            capabilities = latestCapabilities
        } else {
            capabilities = try await probe()
        }
        let requestID = requestIDsByIdempotencyKey[idempotencyKey]
            ?? "lookup-" + JSONSupport.sha256Hex(idempotencyKey)
        return try normalize(turn, requestID: requestID, capabilities: capabilities)
    }

    public func cancel(requestID: String) async {
        guard !requestID.isEmpty,
              requestID.utf8.count <= ManagedModelProviderContract.maximumIdentifierBytes else {
            return
        }
        await transport.cancel(operationID: requestID)
    }

    private func durableReceipt(
        idempotencyKey: String,
        requestFingerprint: String
    ) async throws -> ProviderTurn? {
        guard let receiptStore,
              let record = try receiptStore.record(
                forIdempotencyKey: idempotencyKey,
                requestFingerprint: requestFingerprint
              ) else { return nil }
        latestCapabilities = record.capabilities
        if let turn = record.turn { return turn }
        if let transportTurn = await transport.receipt(
            forIdempotencyKey: idempotencyKey
        ) {
            let normalized = try normalize(
                transportTurn,
                requestID: record.requestID,
                capabilities: record.capabilities
            )
            try receiptStore.accept(
                idempotencyKey: idempotencyKey,
                requestFingerprint: requestFingerprint,
                turn: normalized,
                capabilities: record.capabilities
            )
            return normalized
        }
        guard receiptStore.intentLeaseExpired(record) else {
            throw LMStudioProviderError.conflict
        }
        return nil
    }

    private func clearRejectedIntentIfDefinitive(
        _ error: Error,
        idempotencyKey: String,
        requestFingerprint: String
    ) {
        guard let providerError = error as? LMStudioProviderError else { return }
        switch providerError {
        case .invalidConfiguration, .unauthorized, .forbidden, .endpointNotFound:
            receiptStore?.removeRejectedIntent(
                idempotencyKey: idempotencyKey,
                requestFingerprint: requestFingerprint
            )
        default:
            break
        }
    }

    private static func requestFingerprint(
        kind: String,
        operationID: UUID,
        modelKey: String,
        previousResponseID: String?,
        input: Data,
        tools: [Data]
    ) throws -> String {
        let object: [String: Any] = [
            "kind": kind,
            "operation_id": operationID.uuidString.lowercased(),
            "model_key": modelKey,
            "previous_response_id": previousResponseID.map { $0 as Any } ?? NSNull(),
            "input_sha256": JSONSupport.sha256Hex(input),
            "tool_sha256": tools.map(JSONSupport.sha256Hex),
        ].compactNSNull()
        return JSONSupport.sha256Hex(try JSONSupport.data(from: object))
    }

    private func remember(requestID: String, forIdempotencyKey key: String) {
        if requestIDsByIdempotencyKey[key] == nil { requestIDOrder.append(key) }
        requestIDsByIdempotencyKey[key] = requestID
        while requestIDOrder.count > Self.maximumRememberedRequestIDs {
            requestIDsByIdempotencyKey.removeValue(forKey: requestIDOrder.removeFirst())
        }
    }

    private func normalize(
        _ turn: LMStudioResponseTurn,
        requestID: String,
        capabilities: ProviderCapabilities
    ) throws -> ProviderTurn {
        guard turn.status == "completed" else {
            throw ManagedModelProviderContractError.incompleteTerminalResponse
        }
        guard turn.model == capabilities.modelKey
                || turn.model == capabilities.providerInstanceID else {
            throw ManagedModelProviderContractError.invalidValue(
                "response model does not match the probed model"
            )
        }
        let calls = try turn.functionCalls.map { call in
            guard let arguments = call.arguments.data(using: .utf8) else {
                throw ManagedModelProviderContractError.invalidValue(
                    "tool arguments are not valid UTF-8"
                )
            }
            return try ProviderToolCall(
                itemID: call.itemID,
                callID: call.callID,
                name: call.name,
                argumentsJSON: arguments
            )
        }
        guard Set(calls.map(\.callID)).count == calls.count else {
            throw ManagedModelProviderContractError.invalidValue(
                "response contains duplicate tool call IDs"
            )
        }
        let usage: ProviderUsage?
        if turn.usageWasReported {
            usage = try ProviderUsage(
                capacity: capabilities.contextLength,
                inputTokens: turn.usage.inputTokens,
                outputTokens: turn.usage.outputTokens,
                totalTokens: turn.usage.totalTokens,
                source: .providerExact,
                confidence: 1
            )
        } else {
            usage = nil
        }
        return try ProviderTurn(
            requestID: requestID,
            responseID: turn.responseID,
            previousResponseID: turn.previousResponseID,
            providerID: providerID,
            providerVersion: capabilities.providerVersion,
            modelKey: capabilities.modelKey,
            providerInstanceID: capabilities.providerInstanceID,
            messages: turn.assistantText.isEmpty ? [] : [turn.assistantText],
            toolCalls: calls,
            structuredOutputJSON: nil,
            usage: usage,
            completed: true,
            finishReason: calls.isEmpty ? .stop : .toolCalls,
            rawArtifactID: nil
        )
    }

    private static func functionTool(_ data: Data) throws -> LMStudioFunctionTool {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManagedModelProviderContractError.invalidValue(
                "tool definition is not valid JSON"
            )
        }
        guard let object = raw as? [String: Any],
              (object["type"] as? String).map({ $0 == "function" }) ?? true,
              let name = object["name"] as? String,
              !name.isEmpty,
              name.utf8.count <= 128,
              let parametersObject = object["parameters"]
                ?? object["inputSchema"]
                ?? object["input_schema"],
              JSONSerialization.isValidJSONObject(parametersObject) else {
            throw ManagedModelProviderContractError.invalidValue(
                "tool definition does not contain a valid function schema"
            )
        }
        let description = object["description"] as? String ?? ""
        guard description.utf8.count <= 4_096 else {
            throw ManagedModelProviderContractError.invalidValue(
                "tool description is oversized"
            )
        }
        let parametersData = try JSONSerialization.data(
            withJSONObject: parametersObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let parameters: LMStudioJSONValue
        do {
            parameters = try JSONDecoder().decode(LMStudioJSONValue.self, from: parametersData)
        } catch {
            throw ManagedModelProviderContractError.invalidValue(
                "tool parameters are not representable JSON"
            )
        }
        return LMStudioFunctionTool(
            name: name,
            description: description,
            parameters: parameters,
            strict: object["strict"] as? Bool ?? true
        )
    }

    private static func continuationInput(_ data: Data) throws -> [LMStudioResponseInput] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManagedModelProviderContractError.invalidValue(
                "continuation input is not valid JSON"
            )
        }
        let values: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            values = array
        } else if let object = raw as? [String: Any] {
            values = [object]
        } else {
            throw ManagedModelProviderContractError.invalidValue(
                "continuation input must contain objects"
            )
        }
        guard !values.isEmpty,
              values.count <= ManagedModelProviderContract.maximumMessageCount else {
            throw ManagedModelProviderContractError.invalidValue(
                "continuation input count is invalid"
            )
        }
        return try values.map { value in
            switch value["type"] as? String ?? "message" {
            case "message":
                guard let role = value["role"] as? String,
                      ["system", "user", "assistant"].contains(role),
                      let text = continuationText(value),
                      !text.isEmpty,
                      text.utf8.count <= ManagedModelProviderContract.maximumInputBytes else {
                    throw ManagedModelProviderContractError.invalidValue(
                        "continuation message is invalid"
                    )
                }
                return .message(role: role, text: text)
            case "function_call_output":
                guard let callID = value["call_id"] as? String,
                      !callID.isEmpty,
                      callID.utf8.count <= 512,
                      let output = value["output"] as? String,
                      !output.isEmpty,
                      output.utf8.count <= ManagedModelProviderContract.maximumInputBytes else {
                    throw ManagedModelProviderContractError.invalidValue(
                        "function call output is invalid"
                    )
                }
                return .functionCallOutput(callID: callID, output: output)
            default:
                throw ManagedModelProviderContractError.invalidValue(
                    "continuation input type is unsupported"
                )
            }
        }
    }

    private static func continuationText(_ value: [String: Any]) -> String? {
        if let text = value["text"] as? String { return text }
        if let text = value["content"] as? String { return text }
        guard let content = value["content"] as? [[String: Any]] else { return nil }
        let fragments = content.compactMap { fragment -> String? in
            let type = fragment["type"] as? String
            guard type == nil || type == "input_text" || type == "output_text" else { return nil }
            return fragment["text"] as? String
        }
        guard fragments.count == content.count else { return nil }
        return fragments.joined()
    }
}

public enum SessionHostAdapterV2Error: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidHandoff(String)
    case acknowledgementMismatch(String)
    case idempotencyConflict
    case candidateQuarantined
    case ledgerIntegrity(String)
    case storageLimit

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid V2 session request: \(detail)"
        case .invalidHandoff(let detail): "Invalid V2 handoff: \(detail)"
        case .acknowledgementMismatch(let detail): "Bootstrap acknowledgment mismatch: \(detail)"
        case .idempotencyConflict: "The idempotency key is bound to different session identity"
        case .candidateQuarantined: "The provider candidate is quarantined"
        case .ledgerIntegrity(let detail): "Managed session ledger integrity failed: \(detail)"
        case .storageLimit: "Managed session ledger reached its record limit"
        }
    }
}

public enum ContinuityHandoffV2Validation {
    public static let schemaVersion = "2.0"
    public static let canonicalizationVersion = "forge-json-c14n-v1"
    public static let maximumEncodedBytes = 128 * 1024

    public static func contentSHA256(forJSONObject object: [String: Any]) throws -> String {
        var content = object
        content.removeValue(forKey: "integrity")
        guard JSONSerialization.isValidJSONObject(content) else {
            throw SessionHostAdapterV2Error.invalidHandoff("handoff is not valid JSON")
        }
        return try ForgeJSONCanonicalizationV1.sha256Hex(of: content)
    }
}

private struct ValidatedContinuityHandoffV2 {
    let handoffID: UUID
    let operationID: UUID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let runID: RunID
    let predecessorSessionID: String
    let contentSHA256: String
    let nonce: String
}

private enum ManagedCandidateStatus: String, Codable {
    case intent
    case providerCreated = "provider_created"
    case retryableFailure = "retryable_failure"
    case blockedFailure = "blocked_failure"
    case accepted
    case quarantined
    case cancelled
}

private struct ManagedBootstrapReceiptV2: Codable, Sendable {
    var acknowledgement: BootstrapAcknowledgementV2
    var internalSessionID: String
    var providerResponseID: String
    var modelKey: String
    var adapterID: String
    var providerUsage: LMStudioUsage?
    var contextLength: Int?
    var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case acknowledgement
        case internalSessionID = "internal_session_id"
        case providerResponseID = "provider_response_id"
        case modelKey = "model_key"
        case adapterID = "adapter_id"
        case providerUsage = "provider_usage"
        case contextLength = "context_length"
        case createdAt = "created_at"
    }

    func materialized() throws -> BootstrapReceipt {
        let budget: ContextBudgetStatus?
        if let providerUsage, let contextLength, contextLength > 0 {
            budget = try ContextBudgetMonitor().exact(
                capacity: contextLength,
                used: providerUsage.totalTokens,
                reserved: 0
            )
        } else {
            budget = nil
        }
        return BootstrapReceipt(
            acknowledgement: acknowledgement,
            internalSessionID: internalSessionID,
            providerResponseID: providerResponseID,
            modelKey: modelKey,
            adapterID: adapterID,
            usage: budget,
            createdAt: createdAt
        )
    }
}

private struct ManagedSessionRecordV2: Codable, Sendable {
    var internalSessionID: String
    var idempotencyKeySHA256: String
    var operationID: String
    var projectID: String
    var projectGeneration: UInt64
    var runID: String
    var predecessorSessionID: String
    var modelKey: String
    var providerVersion: String?
    var providerCapabilityFingerprintSHA256: String?
    var handoffID: String
    var handoffSHA256: String
    var nonce: String
    var acknowledgementContractVersion: Int
    var providerRequestID: String
    var providerResponseID: String?
    var quarantinedProviderResponseIDs: [String]
    var attempt: Int
    var status: ManagedCandidateStatus
    var receipt: ManagedBootstrapReceiptV2?
    var receiptSHA256: String?
    var errorCode: String?
    var createdAt: String
    var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case internalSessionID = "internal_session_id"
        case idempotencyKeySHA256 = "idempotency_key_sha256"
        case operationID = "operation_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case predecessorSessionID = "predecessor_session_id"
        case modelKey = "model_key"
        case providerVersion = "provider_version"
        case providerCapabilityFingerprintSHA256 = "provider_capability_fingerprint_sha256"
        case handoffID = "handoff_id"
        case handoffSHA256 = "handoff_sha256"
        case nonce
        case acknowledgementContractVersion = "acknowledgement_contract_version"
        case providerRequestID = "provider_request_id"
        case providerResponseID = "provider_response_id"
        case quarantinedProviderResponseIDs = "quarantined_provider_response_ids"
        case attempt, status, receipt
        case receiptSHA256 = "receipt_sha256"
        case errorCode = "error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct ManagedLegacyQuarantineRecord: Codable, Sendable {
    var sourceRecordSHA256: String
    var reason: String
    var migratedAt: String

    private enum CodingKeys: String, CodingKey {
        case sourceRecordSHA256 = "source_record_sha256"
        case reason
        case migratedAt = "migrated_at"
    }
}

private struct ManagedReconciliationRecordV2: Codable, Sendable {
    var idempotencyKeySHA256: String
    var operationID: String
    var projectID: String
    var projectGeneration: UInt64
    var runID: String
    var predecessorSessionID: String
    var modelKey: String
    var providerVersion: String?
    var providerCapabilityFingerprintSHA256: String?
    var handoffID: String
    var handoffSHA256: String
    var nonce: String
    var acknowledgementContractVersion: Int
    var status: ManagedCandidateStatus
    var receipt: ManagedBootstrapReceiptV2?
    var receiptSHA256: String?
    var errorCode: String?
    var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case idempotencyKeySHA256 = "idempotency_key_sha256"
        case operationID = "operation_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case predecessorSessionID = "predecessor_session_id"
        case modelKey = "model_key"
        case providerVersion = "provider_version"
        case providerCapabilityFingerprintSHA256 = "provider_capability_fingerprint_sha256"
        case handoffID = "handoff_id"
        case handoffSHA256 = "handoff_sha256"
        case nonce
        case acknowledgementContractVersion = "acknowledgement_contract_version"
        case status, receipt
        case receiptSHA256 = "receipt_sha256"
        case errorCode = "error_code"
        case updatedAt = "updated_at"
    }

    init(record: ManagedSessionRecordV2) {
        idempotencyKeySHA256 = record.idempotencyKeySHA256
        operationID = record.operationID
        projectID = record.projectID
        projectGeneration = record.projectGeneration
        runID = record.runID
        predecessorSessionID = record.predecessorSessionID
        modelKey = record.modelKey
        providerVersion = record.providerVersion
        providerCapabilityFingerprintSHA256 = record.providerCapabilityFingerprintSHA256
        handoffID = record.handoffID
        handoffSHA256 = record.handoffSHA256
        nonce = record.nonce
        acknowledgementContractVersion = record.acknowledgementContractVersion
        status = record.status
        receipt = record.receipt
        receiptSHA256 = record.receiptSHA256
        errorCode = record.errorCode
        updatedAt = record.updatedAt
    }
}

private struct ManagedSessionLedgerV2: Codable, Sendable {
    var schemaVersion = 2
    var records: [ManagedSessionRecordV2] = []
    var reconciliationRecords: [ManagedReconciliationRecordV2] = []
    var legacyQuarantine: [ManagedLegacyQuarantineRecord] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
        case reconciliationRecords = "reconciliation_records"
        case legacyQuarantine = "legacy_quarantine"
    }

    init(
        records: [ManagedSessionRecordV2] = [],
        reconciliationRecords: [ManagedReconciliationRecordV2] = [],
        legacyQuarantine: [ManagedLegacyQuarantineRecord] = []
    ) {
        self.records = records
        self.reconciliationRecords = reconciliationRecords
        self.legacyQuarantine = legacyQuarantine
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        records = try values.decodeIfPresent(
            [ManagedSessionRecordV2].self, forKey: .records
        ) ?? []
        reconciliationRecords = try values.decodeIfPresent(
            [ManagedReconciliationRecordV2].self, forKey: .reconciliationRecords
        ) ?? []
        legacyQuarantine = try values.decodeIfPresent(
            [ManagedLegacyQuarantineRecord].self, forKey: .legacyQuarantine
        ) ?? []
    }
}

public actor LMStudioManagedSessionHostAdapterV2: SessionHostAdapterV2 {
    public static let maximumLedgerBytes = 4 * 1024 * 1024
    public static let maximumRecords = 1024
    public static let maximumReconciliationRecords = 4096
    public static let maximumLiveTerminalRecords = 128
    public static let maximumProviderAttempts = 3
    public static let maximumMigrationLineages = 4
    public static let acknowledgementToolName = "forge_continuity_ack"

    public nonisolated let identifier = ForgeNativeSessionHostPlugin.identifier
    public nonisolated let version = ForgeNativeSessionHostPlugin.version
    public nonisolated let transport: any LMStudioManagedTransporting

    private let ledgerURL: URL
    private var ledger: ManagedSessionLedgerV2

    public init(
        storageDirectory: URL,
        transport: any LMStudioManagedTransporting
    ) throws {
        try FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true
        )
        let resolvedLedgerURL = storageDirectory.appendingPathComponent(
            "native-session-ledger.json", isDirectory: false
        )
        ledgerURL = resolvedLedgerURL
        self.transport = transport
        let resolvedLedger = try VerifiedMigrationBackup.withMigrationLock(
            databaseURL: resolvedLedgerURL,
            timeoutSeconds: 60
        ) {
            var loaded = try Self.loadLedger(from: resolvedLedgerURL)
            let ledgerExists = FileManager.default.fileExists(atPath: resolvedLedgerURL.path)
            let observedVersion = ledgerExists ? (loaded.migrated ? 1 : 2) : 0
            if let manifest = try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: resolvedLedgerURL,
                observedVersion: observedVersion,
                allowCompletedFileLineageRestart: loaded.migrated
            ), observedVersion == manifest.sourceVersion {
                let installed = try VerifiedMigrationBackup.installFileMigrationTarget(
                    sourceURL: resolvedLedgerURL,
                    manifest: manifest
                )
                if manifest.state == .prepared {
                    _ = try VerifiedMigrationBackup.completeMigrationManifest(
                        sourceURL: resolvedLedgerURL,
                        preparedManifest: manifest,
                        observedVersion: manifest.targetVersion,
                        targetMetadata: installed
                    )
                }
                loaded = try Self.loadLedger(from: resolvedLedgerURL)
            }

            if loaded.migrated {
                let backupURL = storageDirectory.appendingPathComponent(
                    "native-session-ledger.pre-migration-v1.json",
                    isDirectory: false
                )
                let targetURL = storageDirectory.appendingPathComponent(
                    "native-session-ledger.schema-v2.target.json",
                    isDirectory: false
                )
                let artifacts = try VerifiedMigrationBackup.prepareFileMigrationArtifacts(
                    sourceURL: resolvedLedgerURL,
                    preferredBackupURL: backupURL,
                    preferredTargetArtifactURL: targetURL,
                    maximumBytes: Self.maximumLedgerBytes,
                    maximumLineages: Self.maximumMigrationLineages
                ) { selectedBackup in
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: selectedBackup.url.path
                    )
                    guard let migratedAt = attributes[.modificationDate] as? Date else {
                        throw SessionHostAdapterV2Error.ledgerIntegrity(
                            "legacy ledger backup has no migration timestamp"
                        )
                    }
                    let verifiedSource = try Self.loadLedger(
                        from: selectedBackup.url,
                        legacyMigratedAt: migratedAt
                    )
                    guard verifiedSource.migrated else {
                        throw SessionHostAdapterV2Error.ledgerIntegrity(
                            "legacy ledger backup did not decode as schema version one"
                        )
                    }
                    return try Self.encodedLedger(verifiedSource.ledger)
                }
                let manifest = try VerifiedMigrationBackup.prepareMigrationManifest(
                    sourceURL: resolvedLedgerURL,
                    backup: artifacts.backup,
                    sourceVersion: 1,
                    targetVersion: 2,
                    storageKind: .file,
                    targetArtifact: artifacts.targetArtifact
                )
                let installed = try VerifiedMigrationBackup.installFileMigrationTarget(
                    sourceURL: resolvedLedgerURL,
                    manifest: manifest
                )
                _ = try VerifiedMigrationBackup.completeMigrationManifest(
                    sourceURL: resolvedLedgerURL,
                    preparedManifest: manifest,
                    observedVersion: 2,
                    targetMetadata: installed
                )
                loaded = try Self.loadLedger(from: resolvedLedgerURL)
            }
            guard !loaded.migrated else {
                throw SessionHostAdapterV2Error.ledgerIntegrity(
                    "ledger migration did not install schema version two"
                )
            }
            return loaded.ledger
        }
        ledger = resolvedLedger
    }

    public func capabilitiesV2() async throws -> HostCapabilitiesV2 {
        let provider = try await transport.probe()
        guard provider.trainedForToolUse,
              provider.contextLength > 0,
              provider.streamingVerified,
              provider.functionToolContractVerified,
              Self.isSHA256(provider.capabilityFingerprintSHA256) else {
            throw LMStudioProviderError.invalidConfiguration(
                "managed mode requires a loaded tool-capable model"
            )
        }
        return HostCapabilitiesV2(
            atomicCreateAndBootstrap: true, freshRoot: true,
            usageReporting: true, idempotencyLookup: true,
            projectGenerationFencing: true
        )
    }

    public func createAndBootstrap(
        request: SessionCreationRequestV2,
        handoffJSON: Data,
        challenge: BootstrapChallenge
    ) async throws -> BootstrapReceipt {
        try validate(request: request, challenge: challenge)
        let handoff = try validate(
            handoffJSON: handoffJSON, request: request, challenge: challenge
        )
        let provider = try await transport.probe()
        guard provider.trainedForToolUse,
              provider.contextLength > 0,
              provider.streamingVerified,
              provider.functionToolContractVerified,
              Self.isSHA256(provider.capabilityFingerprintSHA256),
              provider.modelKey == request.modelKey else {
            throw LMStudioProviderError.invalidConfiguration(
                "managed mode requires the requested loaded tool-capable model"
            )
        }
        let keyDigest = JSONSupport.sha256Hex(request.idempotencyKey)

        if let reconciled = ledger.reconciliationRecords.first(where: {
            $0.idempotencyKeySHA256 == keyDigest
        }) {
            guard identityMatches(
                reconciled, request: request, handoff: handoff, challenge: challenge
            ) else {
                throw SessionHostAdapterV2Error.idempotencyConflict
            }
            switch reconciled.status {
            case .accepted:
                guard let receipt = reconciled.receipt else {
                    throw SessionHostAdapterV2Error.ledgerIntegrity(
                        "accepted reconciliation record lacks a receipt"
                    )
                }
                try Self.validatePersistedReceipt(reconciled)
                return try receipt.materialized()
            case .blockedFailure:
                throw persistedFailure(code: reconciled.errorCode)
            case .cancelled:
                throw LMStudioProviderError.cancelled
            case .quarantined:
                throw SessionHostAdapterV2Error.candidateQuarantined
            default:
                throw SessionHostAdapterV2Error.ledgerIntegrity(
                    "nonterminal record was compacted"
                )
            }
        }

        if let index = ledger.records.firstIndex(where: {
            $0.idempotencyKeySHA256 == keyDigest
        }) {
            guard identityMatches(
                ledger.records[index], request: request,
                handoff: handoff, challenge: challenge
            ) else {
                if ledger.records[index].status != .accepted {
                    ledger.records[index].status = .quarantined
                    ledger.records[index].errorCode = "idempotency_identity_conflict"
                    ledger.records[index].updatedAt = ISO8601.string(from: Date())
                    try persist()
                }
                throw SessionHostAdapterV2Error.idempotencyConflict
            }
            if ledger.records[index].status == .accepted,
               let receipt = ledger.records[index].receipt {
                try Self.validatePersistedReceipt(ledger.records[index])
                return try receipt.materialized()
            }
            if ledger.records[index].status == .quarantined {
                throw SessionHostAdapterV2Error.candidateQuarantined
            }
            if ledger.records[index].status == .blockedFailure {
                throw persistedFailure(code: ledger.records[index].errorCode)
            }
            if ledger.records[index].attempt >= Self.maximumProviderAttempts {
                ledger.records[index].status = .quarantined
                ledger.records[index].errorCode = "provider_attempt_limit"
                ledger.records[index].updatedAt = ISO8601.string(from: Date())
                try persist()
                throw SessionHostAdapterV2Error.candidateQuarantined
            }
        }

        if let acceptedKey = acceptedKeyDigest(operationID: request.operationID),
           acceptedKey != keyDigest {
            try appendQuarantinedDuplicate(
                request: request, handoff: handoff,
                challenge: challenge, keyDigest: keyDigest
            )
            throw SessionHostAdapterV2Error.candidateQuarantined
        }

        if let existing = ledger.records.firstIndex(where: {
            $0.idempotencyKeySHA256 == keyDigest
        }) {
            ledger.records[existing].status = .intent
            ledger.records[existing].errorCode = nil
            ledger.records[existing].providerVersion = provider.providerVersion
            ledger.records[existing].providerCapabilityFingerprintSHA256 =
                provider.capabilityFingerprintSHA256
            if let prior = ledger.records[existing].providerResponseID {
                ledger.records[existing].quarantinedProviderResponseIDs.append(prior)
                ledger.records[existing].providerResponseID = nil
            }
            ledger.records[existing].attempt += 1
            ledger.records[existing].providerRequestID = providerRequestID(
                operationID: request.operationID,
                attempt: ledger.records[existing].attempt
            )
            ledger.records[existing].updatedAt = ISO8601.string(from: Date())
        } else {
            try ensureCapacity()
            let now = ISO8601.string(from: Date())
            ledger.records.append(ManagedSessionRecordV2(
                internalSessionID: UUID().uuidString.lowercased(),
                idempotencyKeySHA256: keyDigest,
                operationID: request.operationID.uuidString.lowercased(),
                projectID: request.projectID.description,
                projectGeneration: request.projectGeneration.rawValue,
                runID: request.runID.description,
                predecessorSessionID: request.predecessorSessionID,
                modelKey: request.modelKey,
                providerVersion: provider.providerVersion,
                providerCapabilityFingerprintSHA256: provider.capabilityFingerprintSHA256,
                handoffID: handoff.handoffID.uuidString.lowercased(),
                handoffSHA256: handoff.contentSHA256,
                nonce: challenge.nonce,
                acknowledgementContractVersion: challenge.acknowledgementContractVersion,
                providerRequestID: providerRequestID(
                    operationID: request.operationID, attempt: 1
                ),
                providerResponseID: nil, quarantinedProviderResponseIDs: [],
                attempt: 1, status: .intent,
                receipt: nil, receiptSHA256: nil, errorCode: nil,
                createdAt: now, updatedAt: now
            ))
        }
        try persist()
        guard let prepared = currentIndex(keyDigest: keyDigest) else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("persisted intent disappeared")
        }

        let rootRequest = LMStudioRootRequest(
            operationID: request.operationID.uuidString.lowercased(),
            providerRequestID: ledger.records[prepared].providerRequestID,
            modelKey: request.modelKey,
            systemPrompt: Self.bootstrapSystemPrompt,
            userInput: try handoffString(handoffJSON),
            tools: [acknowledgementTool(request: request, handoff: handoff, challenge: challenge)],
            idempotencyKey: request.idempotencyKey
        )

        let turn: LMStudioResponseTurn
        do {
            turn = if let reconciled = await transport.receipt(
                forIdempotencyKey: request.idempotencyKey
            ) {
                reconciled
            } else {
                try await transport.createRoot(rootRequest)
            }
        } catch {
            if let current = currentIndex(keyDigest: keyDigest),
               ledger.records[current].status != .accepted,
               ledger.records[current].status != .cancelled {
                ledger.records[current].status = failureStatus(error)
                ledger.records[current].errorCode = errorCode(error)
                ledger.records[current].updatedAt = ISO8601.string(from: Date())
                try? persist()
            }
            throw error
        }

        guard let current = currentIndex(keyDigest: keyDigest) else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("candidate disappeared")
        }
        if ledger.records[current].status == .cancelled {
            throw LMStudioProviderError.cancelled
        }
        if ledger.records[current].status == .quarantined {
            throw SessionHostAdapterV2Error.candidateQuarantined
        }
        if ledger.records[current].status == .blockedFailure {
            throw persistedFailure(code: ledger.records[current].errorCode)
        }
        if ledger.records[current].status == .accepted,
           let receipt = ledger.records[current].receipt {
            try Self.validatePersistedReceipt(ledger.records[current])
            return try receipt.materialized()
        }
        ledger.records[current].providerResponseID = turn.responseID
        ledger.records[current].modelKey = request.modelKey
        ledger.records[current].status = .providerCreated
        ledger.records[current].updatedAt = ISO8601.string(from: Date())
        try persist()

        do {
            guard turn.previousResponseID == nil else {
                throw SessionHostAdapterV2Error.acknowledgementMismatch(
                    "provider response is not a fresh root"
                )
            }
            guard turn.status == "completed",
                  turn.model == request.modelKey
                    || turn.model == provider.loadedInstanceID else {
                throw SessionHostAdapterV2Error.acknowledgementMismatch(
                    "provider completion or model does not match"
                )
            }
            try LMStudioProviderIdentifier.validate(turn.responseID)
            let acknowledgement = try validateAcknowledgement(
                turn, request: request, handoff: handoff, challenge: challenge
            )

            if let otherKey = acceptedKeyDigest(operationID: request.operationID),
               otherKey != keyDigest {
                ledger.records[current].status = .quarantined
                ledger.records[current].errorCode = "duplicate_operation_candidate"
                ledger.records[current].updatedAt = ISO8601.string(from: Date())
                try persist()
                throw SessionHostAdapterV2Error.candidateQuarantined
            }

            let receipt = ManagedBootstrapReceiptV2(
                acknowledgement: acknowledgement,
                internalSessionID: ledger.records[current].internalSessionID,
                providerResponseID: turn.responseID, modelKey: request.modelKey,
                adapterID: identifier,
                providerUsage: turn.usageWasReported ? turn.usage : nil,
                contextLength: turn.usageWasReported ? provider.contextLength : nil,
                createdAt: ISO8601.string(from: Date())
            )
            ledger.records[current].receipt = receipt
            ledger.records[current].receiptSHA256 = try Self.receiptSHA256(receipt)
            ledger.records[current].status = .accepted
            ledger.records[current].errorCode = nil
            ledger.records[current].updatedAt = ISO8601.string(from: Date())
            try persist()
            return try receipt.materialized()
        } catch {
            if ledger.records[current].status != .accepted {
                ledger.records[current].status = .quarantined
                ledger.records[current].errorCode = errorCode(error)
                ledger.records[current].updatedAt = ISO8601.string(from: Date())
                try? persist()
            }
            throw error
        }
    }

    public func receipt(forIdempotencyKey key: String) async throws -> BootstrapReceipt? {
        try validateString(key, field: "idempotency key", maximumBytes: 1024)
        let digest = JSONSupport.sha256Hex(key)
        guard let record = ledger.records.first(where: {
            $0.idempotencyKeySHA256 == digest && $0.status == .accepted
        }) else {
            guard let reconciled = ledger.reconciliationRecords.first(where: {
                $0.idempotencyKeySHA256 == digest && $0.status == .accepted
            }), let receipt = reconciled.receipt else { return nil }
            try Self.validatePersistedReceipt(reconciled)
            return try receipt.materialized()
        }
        guard let receipt = record.receipt else {
            throw SessionHostAdapterV2Error.ledgerIntegrity(
                "accepted record lacks a receipt"
            )
        }
        try Self.validatePersistedReceipt(record)
        return try receipt.materialized()
    }

    public func cancel(operationID: UUID) async {
        let operation = operationID.uuidString.lowercased()
        let now = ISO8601.string(from: Date())
        for index in ledger.records.indices
        where ledger.records[index].operationID == operation
            && ledger.records[index].status != .accepted
            && ledger.records[index].status != .quarantined {
            ledger.records[index].status = .cancelled
            ledger.records[index].errorCode = "cancelled"
            ledger.records[index].updatedAt = now
        }
        try? persist()
        await transport.cancel(operationID: operation)
    }

    public func candidateStatus(forIdempotencyKey key: String) -> String? {
        guard !key.isEmpty, key.utf8.count <= 1024,
              !key.contains("\n"), !key.contains("\r") else { return nil }
        let digest = JSONSupport.sha256Hex(key)
        return ledger.records.first { $0.idempotencyKeySHA256 == digest }?.status.rawValue
            ?? ledger.reconciliationRecords.first {
                $0.idempotencyKeySHA256 == digest
            }?.status.rawValue
    }

    public func legacyQuarantineCount() -> Int { ledger.legacyQuarantine.count }

    @discardableResult
    public func compactTerminalLedger(
        retainingRecentTerminalRecords: Int = maximumLiveTerminalRecords
    ) throws -> Int {
        guard retainingRecentTerminalRecords >= 0,
              retainingRecentTerminalRecords <= Self.maximumRecords else {
            throw SessionHostAdapterV2Error.invalidRequest(
                "terminal ledger retention is invalid"
            )
        }
        let compacted = try compactTerminalRecords(
            retainingRecent: retainingRecentTerminalRecords
        )
        if compacted > 0 { try Self.persist(ledger, to: ledgerURL) }
        return compacted
    }

    private static let bootstrapSystemPrompt = """
    This instruction governs only the fresh-root bootstrap response. Validate the bounded Forge continuity handoff and call forge_continuity_ack exactly once with every required identity field. Do not call any other tool or continue project work in the bootstrap response. In a later response rooted at this one, treat acknowledgement as complete, do not call forge_continuity_ack again, and follow the new continuation input.
    """

    private func validate(
        request: SessionCreationRequestV2,
        challenge: BootstrapChallenge
    ) throws {
        guard request.projectGeneration.rawValue >= 1,
              request.projectGeneration.rawValue <= UInt64(Int.max) else {
            throw SessionHostAdapterV2Error.invalidRequest("project generation must be positive")
        }
        try validateString(
            request.predecessorSessionID, field: "predecessor session", maximumBytes: 1024
        )
        try validateString(request.modelKey, field: "model key", maximumBytes: 1024)
        try validateString(request.idempotencyKey, field: "idempotency key", maximumBytes: 1024)
        guard challenge.acknowledgementContractVersion == 2,
              challenge.nonce.utf8.count >= 32,
              challenge.nonce.utf8.count <= 512,
              !challenge.nonce.contains("\n"), !challenge.nonce.contains("\r") else {
            throw SessionHostAdapterV2Error.invalidRequest("bootstrap challenge is invalid")
        }
    }

    private func validate(
        handoffJSON: Data,
        request: SessionCreationRequestV2,
        challenge: BootstrapChallenge
    ) throws -> ValidatedContinuityHandoffV2 {
        guard !handoffJSON.isEmpty,
              handoffJSON.count <= ContinuityHandoffV2Validation.maximumEncodedBytes,
              let handoffText = String(data: handoffJSON, encoding: .utf8) else {
            throw SessionHostAdapterV2Error.invalidHandoff("payload is empty, oversized, or not UTF-8")
        }
        guard !LMStudioRedaction.containsSecretLikeContent(handoffText) else {
            throw SessionHostAdapterV2Error.invalidHandoff("payload contains secret-like content")
        }
        guard let root = try JSONSerialization.jsonObject(with: handoffJSON) as? [String: Any] else {
            throw SessionHostAdapterV2Error.invalidHandoff("payload is not a JSON object")
        }
        guard let contract = ContinuityHandoffV2.fromDictionary(root) else {
            throw SessionHostAdapterV2Error.invalidHandoff("payload does not satisfy the V2 schema")
        }
        do {
            _ = try contract.validated()
        } catch {
            throw SessionHostAdapterV2Error.invalidHandoff("payload does not satisfy the V2 schema")
        }
        let topLevelKeys: Set<String> = [
            "schema_version", "handoff_id", "operation_id", "created_at", "project", "run",
            "predecessor_session", "mission", "constraints", "current_work", "completed_work",
            "open_work", "decisions", "validation", "memory_references", "evidence_references",
            "next_actions", "context_budget", "bootstrap", "integrity",
        ]
        guard Set(root.keys) == topLevelKeys,
              root["schema_version"] as? String == ContinuityHandoffV2Validation.schemaVersion,
              let handoffIDString = root["handoff_id"] as? String,
              let handoffID = UUID(uuidString: handoffIDString),
              let operationIDString = root["operation_id"] as? String,
              let operationID = UUID(uuidString: operationIDString),
              operationID == request.operationID,
              let createdAt = root["created_at"] as? String,
              ISO8601.date(from: createdAt) != nil,
              let mission = root["mission"] as? String, !mission.isEmpty,
              root["constraints"] is [Any], root["completed_work"] is [Any],
              root["open_work"] is [Any], root["decisions"] is [Any],
              root["memory_references"] is [Any], root["evidence_references"] is [Any],
              let nextActions = root["next_actions"] as? [Any], !nextActions.isEmpty,
              root["current_work"] is [String: Any],
              root["validation"] is [String: Any],
              root["context_budget"] is [String: Any] else {
            throw SessionHostAdapterV2Error.invalidHandoff("top-level contract is incomplete")
        }

        guard let project = root["project"] as? [String: Any],
              Set(project.keys) == [
                "project_id", "generation", "display_name", "repository_root",
                "branch", "commit", "dirty_summary",
              ],
              let projectIDString = project["project_id"] as? String,
              let projectUUID = UUID(uuidString: projectIDString),
              ProjectID(projectUUID) == request.projectID,
              let generation = project["generation"] as? Int,
              generation >= 1,
              UInt64(generation) == request.projectGeneration.rawValue else {
            throw SessionHostAdapterV2Error.invalidHandoff("project identity does not match")
        }
        guard let run = root["run"] as? [String: Any],
              Set(run.keys) == ["run_id", "continuity_mode", "assignment_id"],
              let runIDString = run["run_id"] as? String,
              let runUUID = UUID(uuidString: runIDString),
              RunID(runUUID) == request.runID,
              run["continuity_mode"] as? String == "managedAutonomous" else {
            throw SessionHostAdapterV2Error.invalidHandoff("run identity or mode does not match")
        }
        guard let predecessor = root["predecessor_session"] as? [String: Any],
              Set(predecessor.keys) == [
                "session_id", "provider_id", "provider_response_id", "adapter_id", "model",
              ],
              let predecessorID = predecessor["session_id"] as? String,
              predecessorID == request.predecessorSessionID,
              let providerID = predecessor["provider_id"] as? String,
              !providerID.isEmpty, providerID.utf8.count <= 256,
              predecessor["provider_response_id"] is String
                || predecessor["provider_response_id"] is NSNull,
              let adapterID = predecessor["adapter_id"] as? String,
              !adapterID.isEmpty, adapterID.utf8.count <= 256,
              let predecessorModel = predecessor["model"] as? String,
              !predecessorModel.isEmpty, predecessorModel.utf8.count <= 1024 else {
            throw SessionHostAdapterV2Error.invalidHandoff("predecessor session does not match")
        }
        guard let bootstrap = root["bootstrap"] as? [String: Any],
              Set(bootstrap.keys) == ["nonce", "acknowledgement_contract_version"],
              bootstrap["nonce"] as? String == challenge.nonce,
              bootstrap["acknowledgement_contract_version"] as? Int
                == challenge.acknowledgementContractVersion else {
            throw SessionHostAdapterV2Error.invalidHandoff("bootstrap challenge does not match")
        }
        guard let integrity = root["integrity"] as? [String: Any],
              Set(integrity.keys) == [
                "canonicalization_version", "content_sha256", "redaction_complete",
              ],
              integrity["canonicalization_version"] as? String
                == ContinuityHandoffV2Validation.canonicalizationVersion,
              integrity["redaction_complete"] as? Bool == true,
              let contentSHA256 = integrity["content_sha256"] as? String,
              Self.isSHA256(contentSHA256),
              try ContinuityHandoffV2Validation.contentSHA256(forJSONObject: root)
                == contentSHA256 else {
            throw SessionHostAdapterV2Error.invalidHandoff("integrity checksum does not match")
        }
        return ValidatedContinuityHandoffV2(
            handoffID: handoffID, operationID: operationID,
            projectID: request.projectID,
            projectGeneration: request.projectGeneration, runID: request.runID,
            predecessorSessionID: predecessorID,
            contentSHA256: contentSHA256, nonce: challenge.nonce
        )
    }

    private func acknowledgementTool(
        request: SessionCreationRequestV2,
        handoff: ValidatedContinuityHandoffV2,
        challenge: BootstrapChallenge
    ) -> LMStudioFunctionTool {
        let required = [
            "acknowledgement_contract_version", "project_id", "project_generation",
            "run_id", "operation_id", "handoff_id", "handoff_sha256", "nonce", "accepted",
        ].map(LMStudioJSONValue.string)
        return LMStudioFunctionTool(
            name: Self.acknowledgementToolName,
            description: "Acknowledge the exact durable Forge handoff identity.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .boolean(false),
                "required": .array(required),
                "properties": .object([
                    "acknowledgement_contract_version": .object([
                        "const": .integer(challenge.acknowledgementContractVersion),
                    ]),
                    "project_id": .object(["const": .string(request.projectID.description)]),
                    "project_generation": .object([
                        "const": .integer(Int(request.projectGeneration.rawValue)),
                    ]),
                    "run_id": .object(["const": .string(request.runID.description)]),
                    "operation_id": .object([
                        "const": .string(request.operationID.uuidString.lowercased()),
                    ]),
                    "handoff_id": .object([
                        "const": .string(handoff.handoffID.uuidString.lowercased()),
                    ]),
                    "handoff_sha256": .object(["const": .string(handoff.contentSHA256)]),
                    "nonce": .object(["const": .string(challenge.nonce)]),
                    "accepted": .object(["const": .boolean(true)]),
                ]),
            ])
        )
    }

    private func validateAcknowledgement(
        _ turn: LMStudioResponseTurn,
        request: SessionCreationRequestV2,
        handoff: ValidatedContinuityHandoffV2,
        challenge: BootstrapChallenge
    ) throws -> BootstrapAcknowledgementV2 {
        guard turn.functionCalls.count == 1,
              let call = turn.functionCalls.first,
              call.name == Self.acknowledgementToolName,
              let object = try JSONSerialization.jsonObject(
                with: Data(call.arguments.utf8)
              ) as? [String: Any] else {
            throw SessionHostAdapterV2Error.acknowledgementMismatch(
                "exactly one typed acknowledgement call is required"
            )
        }
        let keys: Set<String> = [
            "acknowledgement_contract_version", "project_id", "project_generation",
            "run_id", "operation_id", "handoff_id", "handoff_sha256", "nonce", "accepted",
        ]
        guard Set(object.keys) == keys,
              object["acknowledgement_contract_version"] as? Int
                == challenge.acknowledgementContractVersion,
              object["project_id"] as? String == request.projectID.description,
              object["project_generation"] as? Int
                == Int(request.projectGeneration.rawValue),
              object["run_id"] as? String == request.runID.description,
              object["operation_id"] as? String
                == request.operationID.uuidString.lowercased(),
              object["handoff_id"] as? String
                == handoff.handoffID.uuidString.lowercased(),
              object["handoff_sha256"] as? String == handoff.contentSHA256,
              object["nonce"] as? String == challenge.nonce,
              object["accepted"] as? Bool == true else {
            throw SessionHostAdapterV2Error.acknowledgementMismatch(
                "identity, checksum, nonce, or acceptance differs"
            )
        }
        return try JSONDecoder().decode(
            BootstrapAcknowledgementV2.self,
            from: Data(call.arguments.utf8)
        )
    }

    private func handoffString(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw SessionHostAdapterV2Error.invalidHandoff("payload is not UTF-8")
        }
        return value
    }

    private func identityMatches(
        _ record: ManagedSessionRecordV2,
        request: SessionCreationRequestV2,
        handoff: ValidatedContinuityHandoffV2,
        challenge: BootstrapChallenge
    ) -> Bool {
        record.operationID == request.operationID.uuidString.lowercased()
            && record.projectID == request.projectID.description
            && record.projectGeneration == request.projectGeneration.rawValue
            && record.runID == request.runID.description
            && record.predecessorSessionID == request.predecessorSessionID
            && record.modelKey == request.modelKey
            && record.handoffID == handoff.handoffID.uuidString.lowercased()
            && record.handoffSHA256 == handoff.contentSHA256
            && record.nonce == challenge.nonce
            && record.acknowledgementContractVersion
                == challenge.acknowledgementContractVersion
    }

    private func identityMatches(
        _ record: ManagedReconciliationRecordV2,
        request: SessionCreationRequestV2,
        handoff: ValidatedContinuityHandoffV2,
        challenge: BootstrapChallenge
    ) -> Bool {
        record.operationID == request.operationID.uuidString.lowercased()
            && record.projectID == request.projectID.description
            && record.projectGeneration == request.projectGeneration.rawValue
            && record.runID == request.runID.description
            && record.predecessorSessionID == request.predecessorSessionID
            && record.modelKey == request.modelKey
            && record.handoffID == handoff.handoffID.uuidString.lowercased()
            && record.handoffSHA256 == handoff.contentSHA256
            && record.nonce == challenge.nonce
            && record.acknowledgementContractVersion
                == challenge.acknowledgementContractVersion
    }

    private func acceptedKeyDigest(operationID: UUID) -> String? {
        let operation = operationID.uuidString.lowercased()
        return ledger.records.first {
            $0.operationID == operation && $0.status == .accepted
        }?.idempotencyKeySHA256 ?? ledger.reconciliationRecords.first {
            $0.operationID == operation && $0.status == .accepted
        }?.idempotencyKeySHA256
    }

    private func appendQuarantinedDuplicate(
        request: SessionCreationRequestV2,
        handoff: ValidatedContinuityHandoffV2,
        challenge: BootstrapChallenge,
        keyDigest: String
    ) throws {
        if ledger.records.contains(where: { $0.idempotencyKeySHA256 == keyDigest })
            || ledger.reconciliationRecords.contains(where: {
                $0.idempotencyKeySHA256 == keyDigest
            }) { return }
        try ensureCapacity()
        let now = ISO8601.string(from: Date())
        ledger.records.append(ManagedSessionRecordV2(
            internalSessionID: UUID().uuidString.lowercased(),
            idempotencyKeySHA256: keyDigest,
            operationID: request.operationID.uuidString.lowercased(),
            projectID: request.projectID.description,
            projectGeneration: request.projectGeneration.rawValue,
            runID: request.runID.description,
            predecessorSessionID: request.predecessorSessionID,
            modelKey: request.modelKey,
            handoffID: handoff.handoffID.uuidString.lowercased(),
            handoffSHA256: handoff.contentSHA256,
            nonce: challenge.nonce,
            acknowledgementContractVersion: challenge.acknowledgementContractVersion,
            providerRequestID: providerRequestID(
                operationID: request.operationID, attempt: 0
            ),
            providerResponseID: nil, quarantinedProviderResponseIDs: [],
            attempt: 0, status: .quarantined,
            receipt: nil, receiptSHA256: nil,
            errorCode: "duplicate_operation_candidate",
            createdAt: now, updatedAt: now
        ))
        try persist()
    }

    private func currentIndex(keyDigest: String) -> Int? {
        ledger.records.firstIndex { $0.idempotencyKeySHA256 == keyDigest }
    }

    private func providerRequestID(operationID: UUID, attempt: Int) -> String {
        "\(operationID.uuidString.lowercased()).\(attempt)"
    }

    private func persistedFailure(code: String?) -> LMStudioProviderError {
        switch code {
        case "unauthorized": .unauthorized
        case "forbidden": .forbidden
        case "endpoint_not_found": .endpointNotFound
        case "context_overflow": .contextOverflow
        case "response_truncated": .responseTruncated
        case "synthetic_provider_identifier": .syntheticProviderIdentifier
        case "limit_exceeded": .limitExceeded("provider response")
        case "malformed_response": .malformedResponse("prior provider response was invalid")
        default: .invalidConfiguration("prior provider failure requires reconfiguration")
        }
    }

    private func ensureCapacity() throws {
        _ = try compactTerminalRecords(
            retainingRecent: Self.maximumLiveTerminalRecords
        )
        guard ledger.records.count < Self.maximumRecords,
              ledger.records.count + ledger.reconciliationRecords.count
                + ledger.legacyQuarantine.count < Self.maximumReconciliationRecords else {
            throw SessionHostAdapterV2Error.storageLimit
        }
    }

    private func compactTerminalRecords(retainingRecent: Int) throws -> Int {
        let terminalIndices = ledger.records.indices.filter {
            Self.isTerminal(ledger.records[$0].status)
        }.sorted {
            let left = ledger.records[$0]
            let right = ledger.records[$1]
            if left.updatedAt == right.updatedAt { return left.idempotencyKeySHA256 < right.idempotencyKeySHA256 }
            return left.updatedAt < right.updatedAt
        }
        let removalCount = max(0, terminalIndices.count - retainingRecent)
        guard removalCount > 0 else { return 0 }
        let indicesToCompact = Array(terminalIndices.prefix(removalCount))
        let additions = indicesToCompact.compactMap { index -> ManagedReconciliationRecordV2? in
            let record = ledger.records[index]
            guard !ledger.reconciliationRecords.contains(where: {
                $0.idempotencyKeySHA256 == record.idempotencyKeySHA256
            }) else { return nil }
            return ManagedReconciliationRecordV2(record: record)
        }
        guard ledger.reconciliationRecords.count + additions.count
                + ledger.legacyQuarantine.count <= Self.maximumReconciliationRecords else {
            throw SessionHostAdapterV2Error.storageLimit
        }
        ledger.reconciliationRecords.append(contentsOf: additions)
        for index in indicesToCompact.sorted(by: >) { ledger.records.remove(at: index) }
        return indicesToCompact.count
    }

    private static func isTerminal(_ status: ManagedCandidateStatus) -> Bool {
        switch status {
        case .accepted, .quarantined, .cancelled, .blockedFailure: true
        case .intent, .providerCreated, .retryableFailure: false
        }
    }

    private func failureStatus(_ error: Error) -> ManagedCandidateStatus {
        guard let provider = error as? LMStudioProviderError else { return .blockedFailure }
        switch provider {
        case .providerUnavailable, .rateLimited, .serverFailure,
             .deadlineExceeded, .conflict:
            return .retryableFailure
        case .cancelled:
            return .cancelled
        case .malformedResponse, .limitExceeded, .syntheticProviderIdentifier:
            return .quarantined
        default:
            return .blockedFailure
        }
    }

    private func errorCode(_ error: Error) -> String {
        if let provider = error as? LMStudioProviderError {
            switch provider {
            case .invalidConfiguration: "invalid_configuration"
            case .providerUnavailable: "provider_unavailable"
            case .unauthorized: "unauthorized"
            case .forbidden: "forbidden"
            case .endpointNotFound: "endpoint_not_found"
            case .conflict: "conflict"
            case .rateLimited: "rate_limited"
            case .serverFailure: "server_failure"
            case .contextOverflow: "context_overflow"
            case .responseTruncated: "response_truncated"
            case .deadlineExceeded: "deadline_exceeded"
            case .cancelled: "cancelled"
            case .malformedResponse: "malformed_response"
            case .limitExceeded: "limit_exceeded"
            case .receiptStorage: "receipt_storage"
            case .syntheticProviderIdentifier: "synthetic_provider_identifier"
            }
        } else if let adapter = error as? SessionHostAdapterV2Error {
            switch adapter {
            case .invalidRequest: "invalid_request"
            case .invalidHandoff: "invalid_handoff"
            case .acknowledgementMismatch: "acknowledgement_mismatch"
            case .idempotencyConflict: "idempotency_conflict"
            case .candidateQuarantined: "candidate_quarantined"
            case .ledgerIntegrity: "ledger_integrity"
            case .storageLimit: "storage_limit"
            }
        } else {
            "provider_error"
        }
    }

    private func validateString(_ value: String, field: String, maximumBytes: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw SessionHostAdapterV2Error.invalidRequest("\(field) is invalid")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
        }
    }

    private static func receiptSHA256(_ receipt: ManagedBootstrapReceiptV2) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return JSONSupport.sha256Hex(try encoder.encode(receipt))
    }

    private static func validatePersistedReceipt(_ record: ManagedSessionRecordV2) throws {
        guard record.status == .accepted,
              let receipt = record.receipt,
              receipt.acknowledgement.accepted,
              let checksum = record.receiptSHA256,
              try receiptSHA256(receipt) == checksum,
              receipt.adapterID == ForgeNativeSessionHostPlugin.identifier,
              UUID(uuidString: receipt.internalSessionID) != nil,
              ISO8601.date(from: receipt.createdAt) != nil,
              receipt.modelKey == record.modelKey,
              receipt.acknowledgement.acknowledgementContractVersion
                == record.acknowledgementContractVersion,
              receipt.acknowledgement.operationID.uuidString.lowercased()
                == record.operationID,
              receipt.acknowledgement.projectID.description == record.projectID,
              receipt.acknowledgement.projectGeneration.rawValue
                == record.projectGeneration,
              receipt.acknowledgement.runID.description == record.runID,
              receipt.acknowledgement.handoffID.uuidString.lowercased()
                == record.handoffID,
              receipt.acknowledgement.handoffSHA256 == record.handoffSHA256,
              receipt.acknowledgement.nonce == record.nonce,
              validUsage(receipt.providerUsage, contextLength: receipt.contextLength) else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("accepted receipt does not match its record")
        }
        try LMStudioProviderIdentifier.validate(receipt.providerResponseID)
    }

    private static func validatePersistedReceipt(
        _ record: ManagedReconciliationRecordV2
    ) throws {
        guard record.status == .accepted,
              let receipt = record.receipt,
              receipt.acknowledgement.accepted,
              let checksum = record.receiptSHA256,
              try receiptSHA256(receipt) == checksum,
              receipt.adapterID == ForgeNativeSessionHostPlugin.identifier,
              UUID(uuidString: receipt.internalSessionID) != nil,
              ISO8601.date(from: receipt.createdAt) != nil,
              receipt.modelKey == record.modelKey,
              receipt.acknowledgement.acknowledgementContractVersion
                == record.acknowledgementContractVersion,
              receipt.acknowledgement.operationID.uuidString.lowercased()
                == record.operationID,
              receipt.acknowledgement.projectID.description == record.projectID,
              receipt.acknowledgement.projectGeneration.rawValue
                == record.projectGeneration,
              receipt.acknowledgement.runID.description == record.runID,
              receipt.acknowledgement.handoffID.uuidString.lowercased()
                == record.handoffID,
              receipt.acknowledgement.handoffSHA256 == record.handoffSHA256,
              receipt.acknowledgement.nonce == record.nonce,
              validUsage(receipt.providerUsage, contextLength: receipt.contextLength) else {
            throw SessionHostAdapterV2Error.ledgerIntegrity(
                "accepted reconciliation receipt does not match its record"
            )
        }
        try LMStudioProviderIdentifier.validate(receipt.providerResponseID)
    }

    private static func validUsage(
        _ usage: LMStudioUsage?, contextLength: Int?
    ) -> Bool {
        guard (usage == nil) == (contextLength == nil) else { return false }
        guard let usage, let contextLength else { return true }
        return contextLength > 0
            && usage.inputTokens >= 0
            && usage.outputTokens >= 0
            && usage.totalTokens >= usage.inputTokens
            && usage.totalTokens >= usage.outputTokens
    }

    private func persist() throws {
        _ = try compactTerminalRecords(
            retainingRecent: Self.maximumLiveTerminalRecords
        )
        try Self.persist(ledger, to: ledgerURL)
    }

    private static func persist(_ ledger: ManagedSessionLedgerV2, to url: URL) throws {
        let data = try encodedLedger(ledger)
        try OwnerOnlyAtomicFile.write(data, to: url)
    }

    private static func encodedLedger(_ ledger: ManagedSessionLedgerV2) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= maximumLedgerBytes else {
            throw SessionHostAdapterV2Error.storageLimit
        }
        return data
    }

    private static func loadLedger(
        from url: URL,
        legacyMigratedAt: Date? = nil
    ) throws -> (ledger: ManagedSessionLedgerV2, migrated: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (ManagedSessionLedgerV2(), false)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= maximumLedgerBytes else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("ledger file is empty or oversized")
        }
        let data = try OwnerOnlyAtomicFile.read(from: url, maximumBytes: maximumLedgerBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("ledger is not a JSON object")
        }
        let schemaVersion = object["schema_version"] as? Int
            ?? object["schemaVersion"] as? Int
        if schemaVersion == 2 {
            let ledger = try JSONDecoder().decode(ManagedSessionLedgerV2.self, from: data)
            try validateLoadedLedger(ledger)
            return (ledger, false)
        }
        if schemaVersion == 1 {
            let records = object["records"] as? [[String: Any]] ?? []
            guard records.count <= maximumRecords else {
                throw SessionHostAdapterV2Error.ledgerIntegrity("legacy ledger has too many records")
            }
            let migratedAt = ISO8601.string(from: legacyMigratedAt ?? Date())
            let quarantined = try records.map { record -> ManagedLegacyQuarantineRecord in
                let canonical = try JSONSerialization.data(
                    withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]
                )
                return ManagedLegacyQuarantineRecord(
                    sourceRecordSHA256: JSONSupport.sha256Hex(canonical),
                    reason: "legacy_v1_untrusted_provider_identity",
                    migratedAt: migratedAt
                )
            }
            return (
                ManagedSessionLedgerV2(records: [], legacyQuarantine: quarantined), true
            )
        }
        throw SessionHostAdapterV2Error.ledgerIntegrity("unsupported ledger schema")
    }

    private static func validateLoadedLedger(_ ledger: ManagedSessionLedgerV2) throws {
        guard ledger.schemaVersion == 2,
              ledger.records.count <= maximumRecords,
              ledger.reconciliationRecords.count <= maximumReconciliationRecords,
              ledger.records.count + ledger.reconciliationRecords.count
                + ledger.legacyQuarantine.count <= maximumReconciliationRecords else {
            throw SessionHostAdapterV2Error.ledgerIntegrity("ledger bounds or version are invalid")
        }
        var keys: Set<String> = []
        var acceptedOperations: Set<String> = []
        for record in ledger.records {
            guard isSHA256(record.idempotencyKeySHA256),
                  isSHA256(record.handoffSHA256),
                  UUID(uuidString: record.internalSessionID) != nil,
                  UUID(uuidString: record.operationID) != nil,
                  UUID(uuidString: record.projectID) != nil,
                  UUID(uuidString: record.runID) != nil,
                  UUID(uuidString: record.handoffID) != nil,
                  record.projectGeneration >= 1,
                  !record.predecessorSessionID.isEmpty,
                  record.predecessorSessionID.utf8.count <= 1024,
                  !record.modelKey.isEmpty,
                  record.modelKey.utf8.count <= 1024,
                  validProviderMetadata(
                    version: record.providerVersion,
                    fingerprint: record.providerCapabilityFingerprintSHA256
                  ),
                  (32...512).contains(record.nonce.utf8.count),
                  keys.insert(record.idempotencyKeySHA256).inserted else {
                throw SessionHostAdapterV2Error.ledgerIntegrity("ledger record identity is invalid")
            }
            guard (0...maximumProviderAttempts).contains(record.attempt),
                  !record.providerRequestID.isEmpty,
                  record.providerRequestID.utf8.count <= 1024,
                  record.quarantinedProviderResponseIDs.count <= maximumProviderAttempts else {
                throw SessionHostAdapterV2Error.ledgerIntegrity("provider attempt metadata is invalid")
            }
            for providerResponseID in record.quarantinedProviderResponseIDs {
                try LMStudioProviderIdentifier.validate(providerResponseID)
            }
            if let providerResponseID = record.providerResponseID {
                try LMStudioProviderIdentifier.validate(providerResponseID)
            }
            if record.status == .accepted {
                guard acceptedOperations.insert(record.operationID).inserted else {
                    throw SessionHostAdapterV2Error.ledgerIntegrity("multiple accepted successors")
                }
                guard record.receipt != nil, record.receiptSHA256 != nil else {
                    throw SessionHostAdapterV2Error.ledgerIntegrity("accepted record lacks receipt")
                }
                try validatePersistedReceipt(record)
            }
        }
        for record in ledger.reconciliationRecords {
            guard isSHA256(record.idempotencyKeySHA256),
                  isSHA256(record.handoffSHA256),
                  UUID(uuidString: record.operationID) != nil,
                  UUID(uuidString: record.projectID) != nil,
                  UUID(uuidString: record.runID) != nil,
                  UUID(uuidString: record.handoffID) != nil,
                  record.projectGeneration >= 1,
                  !record.predecessorSessionID.isEmpty,
                  record.predecessorSessionID.utf8.count <= 1024,
                  !record.modelKey.isEmpty,
                  record.modelKey.utf8.count <= 1024,
                  validProviderMetadata(
                    version: record.providerVersion,
                    fingerprint: record.providerCapabilityFingerprintSHA256
                  ),
                  (32...512).contains(record.nonce.utf8.count),
                  isTerminal(record.status),
                  ISO8601.date(from: record.updatedAt) != nil,
                  keys.insert(record.idempotencyKeySHA256).inserted else {
                throw SessionHostAdapterV2Error.ledgerIntegrity(
                    "reconciliation record identity is invalid"
                )
            }
            if record.status == .accepted {
                guard acceptedOperations.insert(record.operationID).inserted else {
                    throw SessionHostAdapterV2Error.ledgerIntegrity(
                        "multiple accepted successors"
                    )
                }
                try validatePersistedReceipt(record)
            } else if record.receipt != nil || record.receiptSHA256 != nil {
                throw SessionHostAdapterV2Error.ledgerIntegrity(
                    "nonaccepted reconciliation record contains a receipt"
                )
            }
        }
        for legacy in ledger.legacyQuarantine {
            guard isSHA256(legacy.sourceRecordSHA256),
                  legacy.reason == "legacy_v1_untrusted_provider_identity",
                  ISO8601.date(from: legacy.migratedAt) != nil else {
                throw SessionHostAdapterV2Error.ledgerIntegrity("legacy quarantine metadata is invalid")
            }
        }
    }

    private static func validProviderMetadata(
        version: String?, fingerprint: String?
    ) -> Bool {
        if let version {
            guard !version.isEmpty, version.utf8.count <= 256,
                  !version.contains("\n"), !version.contains("\r"),
                  !LMStudioRedaction.containsSecretLikeContent(version) else { return false }
        }
        if let fingerprint, !isSHA256(fingerprint) { return false }
        return true
    }
}

public actor LMStudioManagedSessionHostAdapter: SessionHostAdapter, SessionHostAdapterV2 {
    public nonisolated let identifier = ForgeNativeSessionHostPlugin.identifier
    public nonisolated let version = ForgeNativeSessionHostPlugin.version
    public nonisolated let transport: any LMStudioManagedTransporting
    public nonisolated let v2Adapter: LMStudioManagedSessionHostAdapterV2

    public init(
        storageDirectory: URL,
        transport: any LMStudioManagedTransporting
    ) throws {
        self.transport = transport
        v2Adapter = try LMStudioManagedSessionHostAdapterV2(
            storageDirectory: storageDirectory, transport: transport
        )
    }

    public func capabilities() async throws -> HostCapabilities {
        _ = try await transport.probe()
        return HostCapabilities(
            create: false, bootstrap: false, usageReporting: true,
            resume: false, idempotency: true, queryByIdempotencyKey: true
        )
    }

    public func providerCapabilities() async throws -> LMStudioProviderCapabilities {
        try await transport.probe()
    }

    public func capabilitiesV2() async throws -> HostCapabilitiesV2 {
        try await v2Adapter.capabilitiesV2()
    }

    public func createAndBootstrap(
        request: SessionCreationRequestV2,
        handoffJSON: Data,
        challenge: BootstrapChallenge
    ) async throws -> BootstrapReceipt {
        try await v2Adapter.createAndBootstrap(
            request: request,
            handoffJSON: handoffJSON,
            challenge: challenge
        )
    }

    public func receipt(forIdempotencyKey key: String) async throws -> BootstrapReceipt? {
        try await v2Adapter.receipt(forIdempotencyKey: key)
    }

    public func cancel(operationID: UUID) async {
        await v2Adapter.cancel(operationID: operationID)
    }

    public func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    public func session(forIdempotencyKey key: String) async throws -> HostSession? { nil }

    public func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    public func awaitAcknowledgement(
        session: HostSession, handoffID: String, timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    public func cancel(operationID: String) async {
        await transport.cancel(operationID: operationID)
    }
}

public enum NativeHostPluginError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case deadlineExceeded
    case malformedResponse(String)
    case rateLimited(retryNanoseconds: UInt64)
    case storageLimit
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Native session operation was cancelled"
        case .deadlineExceeded: "Native session operation exceeded its deadline"
        case .malformedResponse(let detail): "Native host returned a malformed response: \(detail)"
        case .rateLimited: "Native host rate limit remained active after bounded retries"
        case .storageLimit: "Native host session ledger reached its configured limit"
        case .sessionNotFound(let id): "Native host session was not found: \(id)"
        }
    }
}

public struct NativeTransportSession: Sendable, Equatable {
    public var providerSessionID: String
    public var model: String?

    public init(providerSessionID: String, model: String? = nil) {
        self.providerSessionID = providerSessionID
        self.model = model
    }
}

public struct NativeBootstrapRequest: Sendable {
    public var operationID: String
    public var projectID: String
    public var successorSessionID: String
    public var providerSessionID: String
    public var handoffID: String
    public var handoffSHA256: String
    public var canonicalHandoff: Data
    public var deadline: ContinuousClock.Instant
}

public struct NativeBootstrapResponse: Sendable {
    public var chunks: [Data]
    public var inputTokens: Int
    public var outputTokens: Int

    public init(chunks: [Data], inputTokens: Int = 0, outputTokens: Int = 0) {
        self.chunks = chunks
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public protocol NativeSessionTransport: Sendable {
    func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession
    func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse
    func cancel(operationID: String, providerSessionID: String?) async
}

public actor LocalLogicalSessionTransport: NativeSessionTransport {
    public static let maximumSessions = 4096
    public static let maximumCancelledOperations = 256
    private var sessions: [String: NativeTransportSession] = [:]
    private var cancelled: Set<String> = []

    public init() {}

    public func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession {
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = sessions[request.idempotencyKey] { return existing }
        if sessions.count >= Self.maximumSessions, let oldest = sessions.keys.sorted().first {
            sessions.removeValue(forKey: oldest)
        }
        let digest = JSONSupport.sha256Hex(request.idempotencyKey)
        let session = NativeTransportSession(
            providerSessionID: "native-\(digest.prefix(24))", model: "forge-logical-session"
        )
        sessions[request.idempotencyKey] = session
        return session
    }

    public func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse {
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        guard ContinuousClock.now < request.deadline else { throw NativeHostPluginError.deadlineExceeded }
        let acknowledgement: [String: Any] = [
            "handoff_id": request.handoffID,
            "successor_session_id": request.successorSessionID,
        ]
        return NativeBootstrapResponse(
            chunks: [try JSONSupport.data(from: acknowledgement)],
            inputTokens: Int(ceil(Double(request.canonicalHandoff.count) / 3.5)), outputTokens: 16
        )
    }

    public func cancel(operationID: String, providerSessionID: String?) async {
        if cancelled.count >= Self.maximumCancelledOperations, let oldest = cancelled.sorted().first {
            cancelled.remove(oldest)
        }
        cancelled.insert(operationID)
    }
}

private enum NativeSessionStatus: String, Codable {
    case creating, created, bootstrapping, acknowledged, cancelled
}

private struct NativeSessionRecord: Codable, Sendable {
    var sessionID: String
    var providerSessionID: String?
    var model: String?
    var operationID: String
    var projectID: String
    var predecessorSessionID: String
    var idempotencyKey: String
    var status: NativeSessionStatus
    var handoffID: String?
    var handoffSHA256: String?
    var inputTokens: Int
    var outputTokens: Int
    var createdAt: String
    var updatedAt: String
}

private struct NativeSessionLedger: Codable {
    var schemaVersion: Int = 1
    var records: [NativeSessionRecord] = []
}

public actor ForgeNativeSessionHostAdapter: SessionHostAdapter {
    public nonisolated let identifier = ForgeNativeSessionHostPlugin.identifier
    public nonisolated let version = ForgeNativeSessionHostPlugin.version

    public static let maximumRecords = 4096
    public static let maximumLedgerBytes = 4 * 1024 * 1024
    public static let maximumResponseChunks = 256
    public static let maximumChunkBytes = 16 * 1024
    public static let maximumResponseBytes = 256 * 1024
    public static let maximumRetries = 3

    private let ledgerURL: URL
    private let transport: any NativeSessionTransport
    private var ledger: NativeSessionLedger
    private var cancelledOperations: Set<String> = []

    public init(storageDirectory: URL, transport: any NativeSessionTransport) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        self.ledgerURL = storageDirectory.appendingPathComponent("native-session-ledger.json")
        self.transport = transport
        self.ledger = try Self.loadLedger(from: ledgerURL)
    }

    public func capabilities() async throws -> HostCapabilities {
        ForgeNativeSessionHostPlugin.manifest.capabilities
    }

    public func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        if cancelledOperations.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = record(idempotencyKey: request.idempotencyKey),
           let providerID = existing.providerSessionID {
            return HostSession(id: existing.sessionID, providerSessionID: providerID, model: existing.model)
        }
        let logicalID: String
        if let pending = record(idempotencyKey: request.idempotencyKey) {
            guard pending.status != .cancelled else { throw NativeHostPluginError.cancelled }
            logicalID = pending.sessionID
        } else {
            try ensureCapacity()
            let now = ISO8601.string(from: Date())
            logicalID = UUID().uuidString.lowercased()
            ledger.records.append(NativeSessionRecord(
                sessionID: logicalID, providerSessionID: nil, model: nil,
                operationID: request.operationID, projectID: request.projectID,
                predecessorSessionID: request.predecessorSessionID,
                idempotencyKey: request.idempotencyKey, status: .creating,
                handoffID: nil, handoffSHA256: nil, inputTokens: 0, outputTokens: 0,
                createdAt: now, updatedAt: now
            ))
            try persist()
        }

        var lastRateLimit: NativeHostPluginError?
        for attempt in 0..<Self.maximumRetries {
            do {
                let provider = try await transport.createSession(
                    request: request, deadline: ContinuousClock.now.advanced(by: .seconds(10))
                )
                if cancelledOperations.contains(request.operationID) {
                    await transport.cancel(
                        operationID: request.operationID, providerSessionID: provider.providerSessionID
                    )
                    throw NativeHostPluginError.cancelled
                }
                try validateIdentifier(provider.providerSessionID, field: "provider_session_id")
                guard let index = index(idempotencyKey: request.idempotencyKey) else {
                    throw NativeHostPluginError.sessionNotFound(logicalID)
                }
                ledger.records[index].providerSessionID = provider.providerSessionID
                ledger.records[index].model = provider.model.map { String($0.prefix(256)) }
                ledger.records[index].status = .created
                ledger.records[index].updatedAt = ISO8601.string(from: Date())
                try persist()
                return HostSession(
                    id: logicalID, providerSessionID: provider.providerSessionID,
                    model: ledger.records[index].model
                )
            } catch let error as NativeHostPluginError {
                guard case .rateLimited(let delay) = error, attempt + 1 < Self.maximumRetries else {
                    throw error
                }
                lastRateLimit = error
                if delay > 0 { try await Task.sleep(nanoseconds: min(delay, 1_000_000_000)) }
            }
        }
        throw lastRateLimit ?? NativeHostPluginError.rateLimited(retryNanoseconds: 0)
    }

    public func session(forIdempotencyKey key: String) async throws -> HostSession? {
        guard let existing = record(idempotencyKey: key),
              let providerID = existing.providerSessionID,
              existing.status != .cancelled else { return nil }
        return HostSession(id: existing.sessionID, providerSessionID: providerID, model: existing.model)
    }

    public func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        let validated = try handoff.validated()
        let canonical = try JSONSupport.data(from: validated.asDictionary())
        guard canonical.count <= ContinuityHandoff.maximumEncodedBytes else {
            throw NativeHostPluginError.malformedResponse("handoff exceeds contract bound")
        }
        guard let index = index(sessionID: session.id),
              let providerID = ledger.records[index].providerSessionID else {
            throw NativeHostPluginError.sessionNotFound(session.id)
        }
        if ledger.records[index].status == .acknowledged,
           ledger.records[index].handoffID == validated.handoffID { return }
        ledger.records[index].status = .bootstrapping
        ledger.records[index].handoffID = validated.handoffID
        ledger.records[index].handoffSHA256 = validated.contentSHA256
        ledger.records[index].updatedAt = ISO8601.string(from: Date())
        try persist()

        let response = try await transport.bootstrap(NativeBootstrapRequest(
            operationID: ledger.records[index].operationID,
            projectID: ledger.records[index].projectID,
            successorSessionID: session.id,
            providerSessionID: providerID,
            handoffID: validated.handoffID,
            handoffSHA256: validated.contentSHA256,
            canonicalHandoff: canonical,
            deadline: ContinuousClock.now.advanced(by: .seconds(10))
        ))
        let acknowledgement = try decodeBoundedAcknowledgement(response.chunks)
        guard acknowledgement["handoff_id"] as? String == validated.handoffID,
              acknowledgement["successor_session_id"] as? String == session.id else {
            throw NativeHostPluginError.malformedResponse("acknowledgment identity mismatch")
        }
        guard response.inputTokens >= 0, response.outputTokens >= 0 else {
            throw NativeHostPluginError.malformedResponse("negative usage")
        }
        ledger.records[index].status = .acknowledged
        ledger.records[index].inputTokens = response.inputTokens
        ledger.records[index].outputTokens = response.outputTokens
        ledger.records[index].updatedAt = ISO8601.string(from: Date())
        try persist()
    }

    public func awaitAcknowledgement(
        session: HostSession, handoffID: String, timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        guard let existing = record(sessionID: session.id),
              existing.status == .acknowledged,
              existing.handoffID == handoffID else {
            throw NativeHostPluginError.deadlineExceeded
        }
        return HandoffAcknowledgement(
            handoffID: handoffID, successorSessionID: session.id, adapterID: identifier
        )
    }

    public func cancel(operationID: String) async {
        if cancelledOperations.count >= 256, let oldest = cancelledOperations.first {
            cancelledOperations.remove(oldest)
        }
        cancelledOperations.insert(operationID)
        let providerID = ledger.records.first { $0.operationID == operationID }?.providerSessionID
        if let index = ledger.records.firstIndex(where: { $0.operationID == operationID }) {
            ledger.records[index].status = .cancelled
            ledger.records[index].updatedAt = ISO8601.string(from: Date())
            try? persist()
        }
        await transport.cancel(operationID: operationID, providerSessionID: providerID)
    }

    public func health() -> [String: Any] {
        [
            "ok": true, "adapter_id": identifier, "version": version,
            "records": ledger.records.count, "maximum_records": Self.maximumRecords,
            "response_bytes": Self.maximumResponseBytes,
            "ledger": ledgerURL.path,
        ]
    }

    private func decodeBoundedAcknowledgement(_ chunks: [Data]) throws -> [String: Any] {
        guard !chunks.isEmpty, chunks.count <= Self.maximumResponseChunks else {
            throw NativeHostPluginError.malformedResponse("response chunk count is outside limits")
        }
        var payload = Data()
        payload.reserveCapacity(min(Self.maximumResponseBytes, chunks.reduce(0) { $0 + $1.count }))
        for chunk in chunks {
            guard chunk.count <= Self.maximumChunkBytes,
                  payload.count + chunk.count <= Self.maximumResponseBytes else {
                throw NativeHostPluginError.malformedResponse("response exceeds streaming limits")
            }
            payload.append(chunk)
        }
        do { return try JSONSupport.object(from: payload) }
        catch { throw NativeHostPluginError.malformedResponse("acknowledgment is not JSON") }
    }

    private func record(idempotencyKey: String) -> NativeSessionRecord? {
        ledger.records.first { $0.idempotencyKey == idempotencyKey }
    }

    private func record(sessionID: String) -> NativeSessionRecord? {
        ledger.records.first { $0.sessionID == sessionID }
    }

    private func index(idempotencyKey: String) -> Int? {
        ledger.records.firstIndex { $0.idempotencyKey == idempotencyKey }
    }

    private func index(sessionID: String) -> Int? {
        ledger.records.firstIndex { $0.sessionID == sessionID }
    }

    private func ensureCapacity() throws {
        guard ledger.records.count >= Self.maximumRecords else { return }
        ledger.records.removeAll { $0.status == .acknowledged || $0.status == .cancelled }
        ledger.records = Array(ledger.records.suffix(Self.maximumRecords - 1))
        guard ledger.records.count < Self.maximumRecords else { throw NativeHostPluginError.storageLimit }
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw NativeHostPluginError.malformedResponse("invalid \(field)")
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= Self.maximumLedgerBytes else {
            throw NativeHostPluginError.storageLimit
        }
        try OwnerOnlyAtomicFile.write(data, to: ledgerURL)
    }

    private static func loadLedger(from url: URL) throws -> NativeSessionLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return NativeSessionLedger() }
        let data = try OwnerOnlyAtomicFile.read(from: url, maximumBytes: maximumLedgerBytes)
        let value = try JSONDecoder().decode(NativeSessionLedger.self, from: data)
        guard value.schemaVersion == 1, value.records.count <= maximumRecords else {
            throw NativeHostPluginError.malformedResponse("unsupported or oversized ledger")
        }
        return value
    }
}

public enum ForgeNativeSessionHostPlugin {
    public static let identifier = "forge.native-session-host"
    public static let version = "2.0.0"
    public typealias ConfigurationSource = @Sendable (URL) throws -> LMStudioProviderConfiguration?
    public typealias AuthorizationSource = @Sendable (
        LMStudioProviderConfiguration, URL
    ) throws -> any LMStudioAuthorizationProviding

    public static let manifest = HostPluginManifest(
        identifier: identifier, version: version, minimumContractVersion: 2,
        hostType: "lmstudio-rest-managed",
        capabilities: HostCapabilities(
            create: true, bootstrap: true, usageReporting: true,
            resume: true, idempotency: true, queryByIdempotencyKey: true
        ),
        configurationKeys: [
            "storage_directory", "base_url", "model_key", "keychain_token_reference",
            "connect_timeout_seconds", "first_byte_timeout_seconds",
            "idle_timeout_seconds", "total_timeout_seconds", "maximum_output_tokens",
        ],
        privacyRequirements: [
            "no complete transcript persistence", "redacted diagnostics",
            "provider secrets remain in macOS Keychain behind an opaque reference",
        ],
        migrationVersion: 2
    )

    public static func register(
        in registry: HostAdapterRegistry = .shared,
        configurationSource: @escaping ConfigurationSource = { directory in
            try LMStudioProviderConfiguration.loadIfPresent(in: directory)
        },
        authorizationSource: @escaping AuthorizationSource = { configuration, _ in
            if let reference = configuration.keychainTokenReference {
                return try LMStudioKeychainAuthorization(reference: reference)
            }
            return LMStudioNoAuthorization()
        }
    ) {
        let transportFactory: @Sendable (URL) throws -> LMStudioManagedSessionTransport = {
            storageDirectory in
            guard let configuration = try configurationSource(storageDirectory) else {
                throw ContinuityRunError.hostCapabilityUnavailable
            }
            let authorization = try authorizationSource(configuration, storageDirectory)
            return try LMStudioManagedSessionTransport(
                configuration: configuration,
                authorization: authorization
            )
        }
        registry.register(
            manifest: manifest,
            managedProviderFactory: { storageDirectory in
                try LMStudioManagedModelProvider(
                    storageDirectory: storageDirectory,
                    transport: try transportFactory(storageDirectory)
                )
            },
            configurationFactory: { storageDirectory in
                LMStudioConfigurationService(storageDirectory: storageDirectory)
            }
        ) { storageDirectory in
            return try LMStudioManagedSessionHostAdapter(
                storageDirectory: storageDirectory,
                transport: try transportFactory(storageDirectory)
            )
        }
    }
}

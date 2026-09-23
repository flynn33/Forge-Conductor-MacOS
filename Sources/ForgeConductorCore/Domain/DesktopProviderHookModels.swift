// DesktopProviderHookModels.swift
// What: Defines the bounded wire contract shared by desktop-host hooks and the manager.
// How: Raw hook JSON is structurally preflighted, converted to immutable values, and
// validated against provider, event, field, depth, node-count, and byte limits.
// Why: Third-party hook input crosses a process boundary before Forge can apply policy.

import CoreFoundation
import Foundation

public enum DesktopProviderHookContract {
    public static let schemaVersion = 1
    public static let maximumInputBytes = 256 * 1_024
    public static let maximumEnvelopeBytes = maximumInputBytes + 4_096
    public static let maximumResponseBytes = 64 * 1_024
    public static let maximumDepth = 16
    public static let maximumNodeCount = 4_096
    public static let maximumKeyBytes = 256
    public static let maximumStringBytes = 64 * 1_024
    public static let maximumSessionIDBytes = 1_024
    public static let maximumWorkingDirectoryBytes = 8 * 1_024
    public static let maximumToolNameBytes = 1_024
    public static let maximumAssistantMessageBytes = 64 * 1_024
    public static let maximumCompletionSummaryBytes = 2_048
    public static let maximumAssignmentContextBytes = 8 * 1_024
    public static let maximumHomePathBytes = 8 * 1_024
    public static let requestTimeoutSeconds: TimeInterval = 8
}

public enum DesktopProviderHookEvent: String, CaseIterable, Codable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}

public enum DesktopProviderHookError: Error, LocalizedError, Sendable, Equatable {
    case invalidProvider
    case invalidEvent
    case invalidArguments
    case inputTooLarge
    case invalidJSON
    case invalidEnvelope
    case structureTooLarge
    case fieldTooLarge(String)
    case eventMismatch
    case invalidEndpoint
    case managerUnavailable
    case invalidResponse
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidProvider: "The desktop provider identifier is invalid."
        case .invalidEvent: "The desktop provider hook event is invalid."
        case .invalidArguments: "The desktop provider hook arguments are invalid."
        case .inputTooLarge: "The desktop provider hook input exceeds its byte bound."
        case .invalidJSON: "The desktop provider hook input is not valid bounded JSON."
        case .invalidEnvelope: "The desktop provider hook envelope is invalid."
        case .structureTooLarge: "The desktop provider hook JSON structure exceeds its bounds."
        case .fieldTooLarge(let field): "The desktop provider hook field \(field) exceeds its bound."
        case .eventMismatch: "The desktop provider hook event does not match the payload."
        case .invalidEndpoint: "The configured manager endpoint is not loopback-only."
        case .managerUnavailable: "The local manager hook endpoint is unavailable."
        case .invalidResponse: "The local manager returned an invalid hook response."
        case .responseTooLarge: "The local manager hook response exceeds its byte bound."
        }
    }
}

/// Immutable JSON representation used after the raw structural preflight.
public enum DesktopProviderHookJSONValue: Sendable, Equatable {
    case object([String: DesktopProviderHookJSONValue])
    case array([DesktopProviderHookJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public var objectValue: [String: DesktopProviderHookJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    public var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    func foundationValue() -> Any {
        switch self {
        case .object(let object):
            return object.mapValues { $0.foundationValue() }
        case .array(let array):
            return array.map { $0.foundationValue() }
        case .string(let string):
            return string
        case .integer(let integer):
            return NSNumber(value: integer)
        case .number(let number):
            return NSNumber(value: number)
        case .bool(let bool):
            return NSNumber(value: bool)
        case .null:
            return NSNull()
        }
    }

    fileprivate static func validatedObject(
        from data: Data,
        maximumBytes: Int
    ) throws -> DesktopProviderHookJSONValue {
        guard data.count <= maximumBytes else {
            throw maximumBytes == DesktopProviderHookContract.maximumResponseBytes
                ? DesktopProviderHookError.responseTooLarge
                : DesktopProviderHookError.inputTooLarge
        }
        let structurallyValidated: Data
        do {
            structurallyValidated = try JSONSupport.validatingIntegerFields(
                in: data,
                maximumBytes: maximumBytes,
                requirement: { _ in nil }
            )
        } catch {
            throw DesktopProviderHookError.invalidJSON
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: structurallyValidated)
        } catch {
            throw DesktopProviderHookError.invalidJSON
        }
        guard raw is [String: Any] else {
            throw DesktopProviderHookError.invalidJSON
        }
        var nodeCount = 0
        return try convert(raw, depth: 0, nodeCount: &nodeCount)
    }

    private static func convert(
        _ value: Any,
        depth: Int,
        nodeCount: inout Int
    ) throws -> DesktopProviderHookJSONValue {
        guard depth <= DesktopProviderHookContract.maximumDepth else {
            throw DesktopProviderHookError.structureTooLarge
        }
        nodeCount += 1
        guard nodeCount <= DesktopProviderHookContract.maximumNodeCount else {
            throw DesktopProviderHookError.structureTooLarge
        }
        if let object = value as? [String: Any] {
            var converted: [String: DesktopProviderHookJSONValue] = [:]
            converted.reserveCapacity(object.count)
            for (key, child) in object {
                guard !key.isEmpty,
                      key.utf8.count <= DesktopProviderHookContract.maximumKeyBytes else {
                    throw DesktopProviderHookError.fieldTooLarge("json_key")
                }
                converted[key] = try convert(
                    child,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                )
            }
            return .object(converted)
        }
        if let array = value as? [Any] {
            var converted: [DesktopProviderHookJSONValue] = []
            converted.reserveCapacity(array.count)
            for child in array {
                converted.append(try convert(
                    child,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                ))
            }
            return .array(converted)
        }
        if let string = value as? String {
            guard string.utf8.count <= DesktopProviderHookContract.maximumStringBytes else {
                throw DesktopProviderHookError.fieldTooLarge("json_string")
            }
            return .string(string)
        }
        if value is NSNull { return .null }
        guard let number = value as? NSNumber else {
            throw DesktopProviderHookError.invalidJSON
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if let integer = Int64(number.stringValue) {
            return .integer(integer)
        }
        let floatingPoint = number.doubleValue
        guard floatingPoint.isFinite else {
            throw DesktopProviderHookError.invalidJSON
        }
        return .number(floatingPoint)
    }
}

public struct DesktopProviderHookRequest: Sendable, Equatable {
    public let providerID: ProviderIntegrationID
    public let event: DesktopProviderHookEvent
    public let payload: DesktopProviderHookJSONValue
    public let sessionID: String?
    public let workingDirectory: String?
    public let toolName: String?
    public let lastAssistantMessage: String?

    public init(
        providerID: ProviderIntegrationID,
        event: DesktopProviderHookEvent,
        hostPayload: Data
    ) throws {
        guard Self.isDesktopProvider(providerID) else {
            throw DesktopProviderHookError.invalidProvider
        }
        let payload = try DesktopProviderHookJSONValue.validatedObject(
            from: hostPayload,
            maximumBytes: DesktopProviderHookContract.maximumInputBytes
        )
        try self.init(providerID: providerID, event: event, payload: payload)
    }

    public init(envelopeData: Data) throws {
        let envelope = try DesktopProviderHookJSONValue.validatedObject(
            from: envelopeData,
            maximumBytes: DesktopProviderHookContract.maximumEnvelopeBytes
        )
        guard case .object(let object) = envelope,
              Set(object.keys) == ["schema_version", "provider_id", "event", "payload"],
              case .integer(let schemaVersion) = object["schema_version"],
              schemaVersion == Int64(DesktopProviderHookContract.schemaVersion),
              let providerRaw = object["provider_id"]?.stringValue,
              let providerID = ProviderIntegrationID(rawValue: providerRaw),
              let eventRaw = object["event"]?.stringValue,
              let event = DesktopProviderHookEvent(rawValue: eventRaw),
              let payload = object["payload"] else {
            throw DesktopProviderHookError.invalidEnvelope
        }
        try self.init(providerID: providerID, event: event, payload: payload)
    }

    private init(
        providerID: ProviderIntegrationID,
        event: DesktopProviderHookEvent,
        payload: DesktopProviderHookJSONValue
    ) throws {
        guard Self.isDesktopProvider(providerID),
              case .object(let object) = payload else {
            throw DesktopProviderHookError.invalidProvider
        }
        let sessionID = try Self.boundedOptionalString(
            Self.providerField(
                in: object,
                providerID: providerID,
                canonical: "session_id",
                grokAlias: "sessionId"
            ),
            field: "session_id",
            maximumBytes: DesktopProviderHookContract.maximumSessionIDBytes
        )
        let workingDirectory = try Self.boundedOptionalString(
            object["cwd"],
            field: "cwd",
            maximumBytes: DesktopProviderHookContract.maximumWorkingDirectoryBytes
        )
        let toolName = try Self.boundedOptionalString(
            Self.providerField(
                in: object,
                providerID: providerID,
                canonical: "tool_name",
                grokAlias: "toolName"
            ),
            field: "tool_name",
            maximumBytes: DesktopProviderHookContract.maximumToolNameBytes
        )
        let lastAssistantMessage = try Self.boundedOptionalNullableString(
            Self.providerField(
                in: object,
                providerID: providerID,
                canonical: "last_assistant_message",
                grokAlias: "lastAssistantMessage"
            ),
            field: "last_assistant_message",
            maximumBytes: DesktopProviderHookContract.maximumAssistantMessageBytes
        )
        let payloadEvent = try Self.boundedOptionalString(
            object["hook_event_name"],
            field: "hook_event_name",
            maximumBytes: 64
        )
        if let payloadEvent, payloadEvent != event.rawValue {
            throw DesktopProviderHookError.eventMismatch
        }
        self.providerID = providerID
        self.event = event
        self.payload = payload
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.toolName = toolName
        self.lastAssistantMessage = lastAssistantMessage
    }

    /// Accepts only a bounded JSON object at the end of the final assistant
    /// message. The exact run identity prevents a stale or copied completion
    /// marker from settling another task in the same desktop session.
    public func completionRequest() -> DesktopProviderCompletionRequest? {
        guard event == .stop, let lastAssistantMessage else { return nil }
        let tail = String(lastAssistantMessage.suffix(16_384))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = tail.range(of: "\"forge_run_status\"", options: .backwards) else {
            return nil
        }
        var cursor = marker.lowerBound
        for _ in 0..<8 {
            guard let opening = tail[..<cursor].lastIndex(of: "{") else { break }
            let candidate = String(tail[opening...])
            if let request = Self.decodeCompletionRequest(candidate) { return request }
            cursor = opening
        }
        return Self.decodeCompletionRequest(tail)
    }

    public func envelopeData() throws -> Data {
        let object: [String: Any] = [
            "schema_version": DesktopProviderHookContract.schemaVersion,
            "provider_id": providerID.rawValue,
            "event": event.rawValue,
            "payload": payload.foundationValue(),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= DesktopProviderHookContract.maximumEnvelopeBytes else {
            throw DesktopProviderHookError.inputTooLarge
        }
        return data
    }

    public func asDictionary() -> [String: Any] {
        [
            "schema_version": DesktopProviderHookContract.schemaVersion,
            "provider_id": providerID.rawValue,
            "event": event.rawValue,
            "payload": payload.foundationValue(),
        ]
    }

    public static func isDesktopProvider(_ providerID: ProviderIntegrationID) -> Bool {
        switch providerID {
        case .claudeDesktop, .codexDesktop, .grokBuild: true
        case .lmStudio: false
        }
    }

    private static func providerField(
        in object: [String: DesktopProviderHookJSONValue],
        providerID: ProviderIntegrationID,
        canonical: String,
        grokAlias: String
    ) throws -> DesktopProviderHookJSONValue? {
        let canonicalValue = object[canonical]
        guard providerID == .grokBuild else { return canonicalValue }
        let aliasValue = object[grokAlias]
        if let canonicalValue, let aliasValue, canonicalValue != aliasValue {
            throw DesktopProviderHookError.invalidEnvelope
        }
        return canonicalValue ?? aliasValue
    }

    private static func boundedOptionalString(
        _ value: DesktopProviderHookJSONValue?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else {
            throw DesktopProviderHookError.invalidJSON
        }
        guard !string.isEmpty, string.utf8.count <= maximumBytes else {
            throw DesktopProviderHookError.fieldTooLarge(field)
        }
        return string
    }

    private static func boundedOptionalNullableString(
        _ value: DesktopProviderHookJSONValue?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case .string(let string) = value else {
            throw DesktopProviderHookError.invalidJSON
        }
        guard string.utf8.count <= maximumBytes else {
            throw DesktopProviderHookError.fieldTooLarge(field)
        }
        return string.isEmpty ? nil : string
    }

    private static func decodeCompletionRequest(
        _ json: String
    ) -> DesktopProviderCompletionRequest? {
        guard json.utf8.count <= 8 * 1_024,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["forge_run_status", "run_id", "summary"]),
              object["forge_run_status"] as? String == "completion_requested",
              let runRaw = object["run_id"] as? String,
              let runUUID = UUID(uuidString: runRaw),
              runUUID.uuidString.lowercased() == runRaw.lowercased(),
              let rawSummary = object["summary"] as? String else {
            return nil
        }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty,
              summary == rawSummary,
              summary.utf8.count <= DesktopProviderHookContract.maximumCompletionSummaryBytes else {
            return nil
        }
        return DesktopProviderCompletionRequest(runID: RunID(runUUID), summary: summary)
    }
}

public struct DesktopProviderCompletionRequest: Sendable, Equatable {
    public let runID: RunID
    public let summary: String

    public init(runID: RunID, summary: String) {
        self.runID = runID
        self.summary = summary
    }
}

public enum DesktopProviderRunHookDirective: Sendable, Equatable {
    case none
    case context(String)
    case continueRun(String)
}

public struct DesktopProviderHookResponse: Sendable, Equatable {
    public let output: DesktopProviderHookJSONValue

    public init(data: Data) throws {
        let output = try DesktopProviderHookJSONValue.validatedObject(
            from: data,
            maximumBytes: DesktopProviderHookContract.maximumResponseBytes
        )
        guard !Self.containsAutomaticAllow(output) else {
            throw DesktopProviderHookError.invalidResponse
        }
        self.output = output
    }

    public init(object: [String: DesktopProviderHookJSONValue]) {
        output = .object(object)
    }

    public static let empty = DesktopProviderHookResponse(object: [:])

    public func encodedData() throws -> Data {
        guard case .object(let object) = output else {
            throw DesktopProviderHookError.invalidResponse
        }
        let data = try JSONSerialization.data(
            withJSONObject: object.mapValues { $0.foundationValue() },
            options: [.sortedKeys]
        )
        guard data.count <= DesktopProviderHookContract.maximumResponseBytes else {
            throw DesktopProviderHookError.responseTooLarge
        }
        return data
    }

    public func asDictionary() -> [String: Any] {
        guard case .object(let object) = output else { return [:] }
        return object.mapValues { $0.foundationValue() }
    }

    private static func containsAutomaticAllow(
        _ value: DesktopProviderHookJSONValue
    ) -> Bool {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let normalized = key.replacingOccurrences(of: "_", with: "").lowercased()
                if normalized == "permissiondecision" || normalized == "decision",
                   child.stringValue?.lowercased() == "allow" {
                    return true
                }
                if containsAutomaticAllow(child) { return true }
            }
            return false
        case .array(let array):
            return array.contains(where: containsAutomaticAllow)
        case .string, .integer, .number, .bool, .null:
            return false
        }
    }
}

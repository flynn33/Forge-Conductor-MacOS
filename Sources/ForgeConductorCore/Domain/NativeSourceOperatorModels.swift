import Foundation

public enum NativeSourceOperatorError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidResponse
    case unavailable

    public var code: String {
        switch self {
        case .invalidRequest: "invalid_source_request"
        case .invalidResponse: "invalid_source_response"
        case .unavailable: "native_source_unavailable"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The native source request is invalid."
        case .invalidResponse: "The manager returned an invalid native source response."
        case .unavailable: "Native source conversation control is unavailable."
        }
    }
}

public struct NativeSourceSendRequest: Sendable, Equatable {
    public static let maximumInputBytes = 16 * 1_024
    public static let maximumBodyBytes = 24 * 1_024
    public let schemaVersion = 1
    public let taskID: UUID
    public let requestID: UUID
    public let input: String
    public let canonicalRequestJSON: Data
    public let requestSHA256: String

    public init(taskID: UUID, requestID: UUID, input: String) throws {
        try self.init(arguments: NativeSourceOperatorWire.identity(taskID: taskID, requestID: requestID)
            .merging(["input": input]) { _, new in new })
    }

    public init(data: Data) throws {
        try self.init(arguments: NativeSourceOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes))
    }

    public init(arguments: [String: Any]) throws {
        try NativeSourceOperatorWire.validate(arguments, required: ["schema_version", "task_id", "request_id", "input"])
        taskID = try NativeSourceOperatorWire.uuid(arguments, "task_id")
        requestID = try NativeSourceOperatorWire.uuid(arguments, "request_id")
        guard let value = arguments["input"] as? String, !value.isEmpty,
              value.utf8.count <= Self.maximumInputBytes, !value.contains("\0") else {
            throw NativeSourceOperatorError.invalidRequest("input")
        }
        input = value
        canonicalRequestJSON = try NativeSourceOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
        requestSHA256 = NativeSourceOperatorWire.requestHash(action: "send", data: canonicalRequestJSON)
    }
}

public struct NativeSourceStatusRequest: Sendable, Equatable {
    public static let maximumBodyBytes = 2_048
    public let schemaVersion = 1
    public let taskID: UUID
    public let requestID: UUID
    public let canonicalRequestJSON: Data

    public init(taskID: UUID, requestID: UUID) throws {
        try self.init(arguments: NativeSourceOperatorWire.identity(taskID: taskID, requestID: requestID))
    }

    public init(data: Data) throws {
        try self.init(arguments: NativeSourceOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes))
    }

    public init(arguments: [String: Any]) throws {
        try NativeSourceOperatorWire.validate(arguments, required: ["schema_version", "task_id", "request_id"])
        taskID = try NativeSourceOperatorWire.uuid(arguments, "task_id")
        requestID = try NativeSourceOperatorWire.uuid(arguments, "request_id")
        canonicalRequestJSON = try NativeSourceOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
    }
}

public struct NativeSourceCancelRequest: Sendable, Equatable {
    public static let maximumBodyBytes = 2_048
    public let schemaVersion = 1
    public let taskID: UUID
    public let requestID: UUID
    public let cancelRequestID: UUID
    public let reason: String?
    public let canonicalRequestJSON: Data
    public let requestSHA256: String

    public init(taskID: UUID, requestID: UUID, cancelRequestID: UUID, reason: String? = nil) throws {
        var object = NativeSourceOperatorWire.identity(taskID: taskID, requestID: requestID)
        object["cancel_request_id"] = cancelRequestID.uuidString.lowercased()
        if let reason { object["reason"] = reason }
        try self.init(arguments: object)
    }

    public init(data: Data) throws {
        try self.init(arguments: NativeSourceOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes))
    }

    public init(arguments: [String: Any]) throws {
        try NativeSourceOperatorWire.validate(arguments,
            required: ["schema_version", "task_id", "request_id", "cancel_request_id"], optional: ["reason"])
        taskID = try NativeSourceOperatorWire.uuid(arguments, "task_id")
        requestID = try NativeSourceOperatorWire.uuid(arguments, "request_id")
        cancelRequestID = try NativeSourceOperatorWire.uuid(arguments, "cancel_request_id")
        if let value = arguments["reason"] {
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw NativeSourceOperatorError.invalidRequest("reason")
            }
            reason = text
        } else { reason = nil }
        canonicalRequestJSON = try NativeSourceOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
        requestSHA256 = NativeSourceOperatorWire.requestHash(action: "cancel", data: canonicalRequestJSON)
    }
}

/// A bounded operator projection, never an execution grant or provider receipt.
public struct NativeSourceOperatorResponse: Sendable, Equatable {
    public static let maximumBytes = 32_768
    public let taskID: UUID
    public let requestID: UUID
    public let conversationID: UUID
    public let stageID: UUID
    public let disposition: String
    public let conversationState: String
    public let stageState: String
    public let canonicalJSON: Data

    public init(data: Data) throws {
        do {
            let checked = try JSONSupport.validatingIntegerFields(in: data, maximumBytes: Self.maximumBytes) {
                ["schema_version", "stage_ordinal", "revision"].contains($0.last ?? "") ? .required : nil
            }
            // The shared count validator preserves legacy integral decimals by
            // rewriting them. This versioned wire requires integer tokens themselves.
            guard checked == data,
                  let object = try JSONSerialization.jsonObject(with: checked) as? [String: Any] else {
                throw NativeSourceOperatorError.invalidResponse
            }
            try self.init(arguments: object)
        } catch { throw NativeSourceOperatorError.invalidResponse }
    }

    public init(arguments: [String: Any]) throws {
        do {
            try NativeTaskOperatorWire.keys(arguments, required: ["schema_version", "ok", "disposition", "task_id",
                "request_id", "conversation_id", "conversation_state", "stage_id", "stage_state", "stage_ordinal",
                "deadline", "intent_sha256"], optional: ["assistant_preview", "assistant_truncated", "assistant_sha256", "handoff"])
            try NativeTaskOperatorWire.version(arguments)
            try NativeSourceOperatorWire.requireIntegerStorage(arguments, "schema_version")
            try NativeSourceOperatorWire.requireIntegerStorage(arguments, "stage_ordinal")
            guard try NativeTaskOperatorWire.boolean(arguments, "ok") else { throw NativeSourceOperatorError.invalidResponse }
            taskID = try NativeTaskOperatorWire.uuid(arguments, "task_id")
            requestID = try NativeTaskOperatorWire.uuid(arguments, "request_id")
            conversationID = try NativeTaskOperatorWire.uuid(arguments, "conversation_id")
            stageID = try NativeTaskOperatorWire.uuid(arguments, "stage_id")
            disposition = try NativeTaskOperatorWire.string(arguments, "disposition", maximum: 32)
            conversationState = try NativeTaskOperatorWire.string(arguments, "conversation_state", maximum: 32)
            stageState = try NativeTaskOperatorWire.string(arguments, "stage_state", maximum: 32)
            guard ["accepted", "replayed", "observed", "cancel_requested"].contains(disposition),
                  ["idle", "active", "stopped", "source_fenced", "reconciliation_required"].contains(conversationState),
                  ["prepared", "submitted", "accepted", "outcome_unknown", "cancelled_before_dispatch"].contains(stageState) else {
                throw NativeSourceOperatorError.invalidResponse
            }
            _ = try NativeTaskOperatorWire.integer(arguments, "stage_ordinal", range: 1...64)
            _ = try NativeTaskOperatorWire.date(arguments, "deadline")
            _ = try NativeTaskOperatorWire.hash(arguments, "intent_sha256")
            let previewKeys: Set<String> = ["assistant_preview", "assistant_truncated", "assistant_sha256"]
            let present = previewKeys.intersection(arguments.keys)
            guard present.isEmpty || present == previewKeys else { throw NativeSourceOperatorError.invalidResponse }
            if !present.isEmpty {
                guard let preview = arguments["assistant_preview"] as? String, preview.utf8.count <= 8_192,
                      !preview.contains("\0") else { throw NativeSourceOperatorError.invalidResponse }
                _ = try NativeTaskOperatorWire.boolean(arguments, "assistant_truncated")
                _ = try NativeTaskOperatorWire.hash(arguments, "assistant_sha256")
            }
            if let value = arguments["handoff"] {
                guard let handoff = value as? [String: Any] else { throw NativeSourceOperatorError.invalidResponse }
                try NativeTaskOperatorWire.keys(handoff, required: ["continuity_id", "revision", "packet_sha256"], optional: ["operation_id"])
                guard let id = handoff["continuity_id"] as? String, ContinuityIngressLimits.validHandoffID(id) else {
                    throw NativeSourceOperatorError.invalidResponse
                }
                try NativeSourceOperatorWire.requireIntegerStorage(handoff, "revision")
                _ = try NativeTaskOperatorWire.integer(handoff, "revision", range: 1...Int.max)
                _ = try NativeTaskOperatorWire.hash(handoff, "packet_sha256")
                if handoff["operation_id"] != nil { _ = try NativeTaskOperatorWire.uuid(handoff, "operation_id") }
            }
            canonicalJSON = try NativeTaskOperatorWire.canonical(arguments, maximumBytes: Self.maximumBytes)
        } catch { throw NativeSourceOperatorError.invalidResponse }
    }
}

enum NativeSourceOperatorWire {
    static func identity(taskID: UUID, requestID: UUID) -> [String: Any] {
        ["schema_version": 1, "task_id": taskID.uuidString.lowercased(), "request_id": requestID.uuidString.lowercased()]
    }

    static func object(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        do {
            let checked = try JSONSupport.validatingIntegerFields(in: data, maximumBytes: maximumBytes) {
                $0 == ["schema_version"] ? .required : nil
            }
            guard checked == data else { throw NativeSourceOperatorError.invalidRequest("schema_version") }
            return try NativeTaskOperatorWire.object(data, maximumBytes: maximumBytes)
        } catch { throw NativeSourceOperatorError.invalidRequest("body") }
    }

    static func requireIntegerStorage(_ object: [String: Any], _ key: String) throws {
        guard let number = object[key] as? NSNumber,
              !["f", "d"].contains(String(cString: number.objCType)),
              JSONSupport.exactInteger(number) != nil else {
            throw NativeSourceOperatorError.invalidRequest(key)
        }
    }

    static func validate(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        do {
            try NativeTaskOperatorWire.keys(object, required: required, optional: optional)
            try NativeTaskOperatorWire.version(object)
            try requireIntegerStorage(object, "schema_version")
        } catch { throw NativeSourceOperatorError.invalidRequest("fields") }
    }

    static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
        do { return try NativeTaskOperatorWire.uuid(object, key) }
        catch { throw NativeSourceOperatorError.invalidRequest(key) }
    }

    static func canonical(_ object: [String: Any], maximumBytes: Int) throws -> Data {
        do { return try NativeTaskOperatorWire.canonical(object, maximumBytes: maximumBytes) }
        catch { throw NativeSourceOperatorError.invalidRequest("body") }
    }

    static func requestHash(action: String, data: Data) -> String {
        var value = Data("forge.continuity.source-operator.v1\0\(action)\0".utf8)
        value.append(data)
        return JSONSupport.sha256Hex(value)
    }
}

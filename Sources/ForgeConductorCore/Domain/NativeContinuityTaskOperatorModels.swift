import CoreFoundation
import Foundation

public enum NativeTaskOperatorError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidCredentialFile
    case credentialConflict
    case credentialInactive
    case reconciliationRequired
    case noPendingRequest
    case invalidResponse
    case responseTooLarge
    case rejected(status: Int, code: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field): "Invalid native task request field: \(field)"
        case .invalidCredentialFile: "The protected native task credential file is invalid"
        case .credentialConflict: "The native task credential changed or already has a pending command"
        case .credentialInactive: "The native task credential is not active"
        case .reconciliationRequired: "The exact pending native task command requires reconciliation"
        case .noPendingRequest: "The native task has no pending operator command"
        case .invalidResponse: "The manager returned an invalid native task response"
        case .responseTooLarge: "The native task response exceeded its byte limit"
        case .rejected(let status, let code): "The manager rejected the native task command (\(status), \(code))"
        }
    }
}

/// Exact operator-approved input. It is not decoded from a model handoff.
public struct NativeContinuityTaskApproval: Sendable, Equatable {
    public let assignmentID: String
    public let assignmentBytes: Data
    public let mission: String
    public let providerID: String
    public let adapterID: String
    public let modelKey: String
    public let allowedTools: [String]
    public let completionGates: [String]
    public let resourceProfile: AutonomyResourceProfile
    public let filesystemAccess: String
    public let networkAllowed: Bool
    public let maximumInlineOutputBytes: Int
    public let sourceLimits: NativeTaskSourceLimits

    public init(assignmentID: String, assignmentBytes: Data, mission: String,
                providerID: String, adapterID: String, modelKey: String,
                allowedTools: [String], completionGates: [String],
                resourceProfile: AutonomyResourceProfile, filesystemAccess: String,
                networkAllowed: Bool, maximumInlineOutputBytes: Int,
                sourceLimits: NativeTaskSourceLimits) throws {
        try self.init(arguments: [
            "assignment_id": assignmentID, "assignment_base64": assignmentBytes.base64EncodedString(),
            "mission": mission, "provider_id": providerID, "adapter_id": adapterID,
            "model_key": modelKey, "allowed_tools": allowedTools, "completion_gates": completionGates,
            "resource_profile": resourceProfile.rawValue, "filesystem_access": filesystemAccess,
            "network_allowed": networkAllowed, "maximum_inline_output_bytes": maximumInlineOutputBytes,
            "source_limits": ["maximum_calls": sourceLimits.maximumCalls,
                              "maximum_result_bytes": sourceLimits.maximumResultBytes,
                              "maximum_request_seconds": sourceLimits.maximumRequestSeconds],
        ])
    }

    public init(arguments: [String: Any]) throws {
        try NativeTaskOperatorWire.keys(arguments, required: ["assignment_id", "assignment_base64", "mission",
            "provider_id", "adapter_id", "model_key", "allowed_tools", "completion_gates", "resource_profile",
            "filesystem_access", "network_allowed", "maximum_inline_output_bytes", "source_limits"])
        assignmentID = try NativeTaskOperatorWire.string(arguments, "assignment_id", maximum: 1_024)
        let encoded = try NativeTaskOperatorWire.string(arguments, "assignment_base64", maximum: 174_764)
        guard let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 131_072,
              bytes.base64EncodedString() == encoded else { throw NativeTaskOperatorError.invalidRequest("assignment_base64") }
        assignmentBytes = bytes
        mission = try NativeTaskOperatorWire.string(arguments, "mission", maximum: 65_536)
        providerID = try NativeTaskOperatorWire.string(arguments, "provider_id", maximum: 256)
        adapterID = try NativeTaskOperatorWire.string(arguments, "adapter_id", maximum: 256)
        modelKey = try NativeTaskOperatorWire.string(arguments, "model_key", maximum: 1_024)
        allowedTools = try NativeTaskOperatorWire.strings(arguments, "allowed_tools", maximumCount: 128, maximumBytes: 256)
        completionGates = try NativeTaskOperatorWire.strings(arguments, "completion_gates", maximumCount: 128, maximumBytes: 512)
        guard let profile = AutonomyResourceProfile(rawValue: try NativeTaskOperatorWire.string(arguments, "resource_profile", maximum: 32)) else {
            throw NativeTaskOperatorError.invalidRequest("resource_profile")
        }
        resourceProfile = profile
        filesystemAccess = try NativeTaskOperatorWire.string(arguments, "filesystem_access", maximum: 32)
        networkAllowed = try NativeTaskOperatorWire.boolean(arguments, "network_allowed")
        maximumInlineOutputBytes = try NativeTaskOperatorWire.integer(arguments, "maximum_inline_output_bytes", range: 1...65_536)
        guard let limits = arguments["source_limits"] as? [String: Any] else {
            throw NativeTaskOperatorError.invalidRequest("source_limits")
        }
        try NativeTaskOperatorWire.keys(limits, required: ["maximum_calls", "maximum_result_bytes", "maximum_request_seconds"])
        sourceLimits = try NativeTaskSourceLimits(
            maximumCalls: NativeTaskOperatorWire.integer(limits, "maximum_calls", range: 1...64),
            maximumResultBytes: NativeTaskOperatorWire.integer(limits, "maximum_result_bytes", range: 1...65_536),
            maximumRequestSeconds: NativeTaskOperatorWire.integer(limits, "maximum_request_seconds", range: 1...60))
        // Reject unsupported approval instead of silently narrowing it.
        guard filesystemAccess == "read_only", !networkAllowed, Set(allowedTools) == ["fs_read"] else {
            throw NativeTaskOperatorError.invalidRequest("approval_scope")
        }
    }

    public func asDictionary() -> [String: Any] {
        ["assignment_id": assignmentID, "assignment_base64": assignmentBytes.base64EncodedString(),
         "mission": mission, "provider_id": providerID, "adapter_id": adapterID, "model_key": modelKey,
         "allowed_tools": allowedTools, "completion_gates": completionGates,
         "resource_profile": resourceProfile.rawValue, "filesystem_access": filesystemAccess,
         "network_allowed": networkAllowed, "maximum_inline_output_bytes": maximumInlineOutputBytes,
         "source_limits": ["maximum_calls": sourceLimits.maximumCalls,
                           "maximum_result_bytes": sourceLimits.maximumResultBytes,
                           "maximum_request_seconds": sourceLimits.maximumRequestSeconds]]
    }
}

public struct NativeContinuityTaskPreparationRequest: Sendable, Equatable {
    public static let maximumBodyBytes = 393_216
    public let schemaVersion = 1
    public let requestID: UUID
    public let taskID: UUID
    public let capabilityID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let profileID: String
    public let profileVersion: Int
    public let approval: NativeContinuityTaskApproval
    public let verifierSHA256: String
    public let expiresAt: String
    public let canonicalRequestJSON: Data
    public let requestSHA256: String
    public var action: String { "prepare" }

    public init(requestID: UUID, taskID: UUID, capabilityID: UUID, projectID: ProjectID,
                projectGeneration: ProjectGeneration, profileID: String = "forge.native-task-source",
                profileVersion: Int = 1, approval: NativeContinuityTaskApproval,
                verifierSHA256: String, expiresAt: String) throws {
        var object = NativeTaskOperatorWire.identity(requestID: requestID, taskID: taskID, capabilityID: capabilityID,
                                                     projectID: projectID, generation: projectGeneration)
        object["profile_id"] = profileID; object["profile_version"] = profileVersion
        object["approval"] = approval.asDictionary(); object["verifier_sha256"] = verifierSHA256
        object["expires_at"] = expiresAt
        try self.init(arguments: object)
    }

    public init(data: Data) throws {
        try self.init(arguments: NativeTaskOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes))
    }

    public init(arguments: [String: Any]) throws {
        try NativeTaskOperatorWire.keys(arguments, required: NativeTaskOperatorWire.identityKeys.union([
            "profile_id", "profile_version", "approval", "verifier_sha256", "expires_at"]))
        try NativeTaskOperatorWire.version(arguments)
        requestID = try NativeTaskOperatorWire.uuid(arguments, "request_id")
        taskID = try NativeTaskOperatorWire.uuid(arguments, "task_id")
        capabilityID = try NativeTaskOperatorWire.uuid(arguments, "capability_id")
        projectID = ProjectID(try NativeTaskOperatorWire.uuid(arguments, "project_id"))
        projectGeneration = ProjectGeneration(UInt64(try NativeTaskOperatorWire.integer(arguments, "project_generation", range: 1...Int.max)))
        profileID = try NativeTaskOperatorWire.string(arguments, "profile_id", maximum: 64)
        profileVersion = try NativeTaskOperatorWire.integer(arguments, "profile_version", range: 1...Int.max)
        guard profileID == "forge.native-task-source", profileVersion == 1,
              let value = arguments["approval"] as? [String: Any] else { throw NativeTaskOperatorError.invalidRequest("profile") }
        approval = try NativeContinuityTaskApproval(arguments: value)
        verifierSHA256 = try NativeTaskOperatorWire.hash(arguments, "verifier_sha256")
        expiresAt = try NativeTaskOperatorWire.date(arguments, "expires_at")
        canonicalRequestJSON = try NativeTaskOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
        requestSHA256 = NativeTaskOperatorWire.requestHash(action: "prepare", data: canonicalRequestJSON)
    }

    public func asDictionary() throws -> [String: Any] { try JSONSupport.object(from: canonicalRequestJSON) }
}

public struct NativeContinuityTaskRotationRequest: Sendable, Equatable {
    public static let maximumBodyBytes = 4_096
    public let schemaVersion = 1
    public let requestID: UUID
    public let taskID: UUID
    public let capabilityID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let expectedEpoch: Int64
    public let verifierSHA256: String
    public let expiresAt: String
    public let canonicalRequestJSON: Data
    public let requestSHA256: String
    public var action: String { "rotate" }

    public init(requestID: UUID, taskID: UUID, capabilityID: UUID, projectID: ProjectID,
                projectGeneration: ProjectGeneration, expectedEpoch: Int64,
                verifierSHA256: String, expiresAt: String) throws {
        var object = NativeTaskOperatorWire.identity(requestID: requestID, taskID: taskID, capabilityID: capabilityID,
                                                     projectID: projectID, generation: projectGeneration)
        object["expected_epoch"] = expectedEpoch; object["verifier_sha256"] = verifierSHA256; object["expires_at"] = expiresAt
        try self.init(arguments: object)
    }

    public init(data: Data) throws { try self.init(arguments: NativeTaskOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes)) }

    public init(arguments: [String: Any]) throws {
        try NativeTaskOperatorWire.keys(arguments, required: NativeTaskOperatorWire.identityKeys.union(["expected_epoch", "verifier_sha256", "expires_at"]))
        try NativeTaskOperatorWire.version(arguments)
        requestID = try NativeTaskOperatorWire.uuid(arguments, "request_id")
        taskID = try NativeTaskOperatorWire.uuid(arguments, "task_id")
        capabilityID = try NativeTaskOperatorWire.uuid(arguments, "capability_id")
        projectID = ProjectID(try NativeTaskOperatorWire.uuid(arguments, "project_id"))
        projectGeneration = ProjectGeneration(UInt64(try NativeTaskOperatorWire.integer(arguments, "project_generation", range: 1...Int.max)))
        expectedEpoch = Int64(try NativeTaskOperatorWire.integer(arguments, "expected_epoch", range: 1...(Int.max - 1)))
        verifierSHA256 = try NativeTaskOperatorWire.hash(arguments, "verifier_sha256")
        expiresAt = try NativeTaskOperatorWire.date(arguments, "expires_at")
        canonicalRequestJSON = try NativeTaskOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
        requestSHA256 = NativeTaskOperatorWire.requestHash(action: "rotate", data: canonicalRequestJSON)
    }

    public func asDictionary() throws -> [String: Any] { try JSONSupport.object(from: canonicalRequestJSON) }
}

public struct NativeContinuityTaskRevocationRequest: Sendable, Equatable {
    public static let maximumBodyBytes = 4_096
    public let schemaVersion = 1
    public let requestID: UUID
    public let taskID: UUID
    public let capabilityID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let expectedEpoch: Int64
    public let reason: String?
    public let canonicalRequestJSON: Data
    public let requestSHA256: String
    public var action: String { "revoke" }

    public init(requestID: UUID, taskID: UUID, capabilityID: UUID, projectID: ProjectID,
                projectGeneration: ProjectGeneration, expectedEpoch: Int64, reason: String? = nil) throws {
        var object = NativeTaskOperatorWire.identity(requestID: requestID, taskID: taskID, capabilityID: capabilityID,
                                                     projectID: projectID, generation: projectGeneration)
        object["expected_epoch"] = expectedEpoch
        if let reason { object["reason"] = reason }
        try self.init(arguments: object)
    }

    public init(data: Data) throws { try self.init(arguments: NativeTaskOperatorWire.object(data, maximumBytes: Self.maximumBodyBytes)) }

    public init(arguments: [String: Any]) throws {
        try NativeTaskOperatorWire.keys(arguments, required: NativeTaskOperatorWire.identityKeys.union(["expected_epoch"]), optional: ["reason"])
        try NativeTaskOperatorWire.version(arguments)
        requestID = try NativeTaskOperatorWire.uuid(arguments, "request_id")
        taskID = try NativeTaskOperatorWire.uuid(arguments, "task_id")
        capabilityID = try NativeTaskOperatorWire.uuid(arguments, "capability_id")
        projectID = ProjectID(try NativeTaskOperatorWire.uuid(arguments, "project_id"))
        projectGeneration = ProjectGeneration(UInt64(try NativeTaskOperatorWire.integer(arguments, "project_generation", range: 1...Int.max)))
        expectedEpoch = Int64(try NativeTaskOperatorWire.integer(arguments, "expected_epoch", range: 1...(Int.max - 1)))
        reason = arguments["reason"] == nil ? nil : try NativeTaskOperatorWire.string(arguments, "reason", maximum: 512)
        canonicalRequestJSON = try NativeTaskOperatorWire.canonical(arguments, maximumBytes: Self.maximumBodyBytes)
        requestSHA256 = NativeTaskOperatorWire.requestHash(action: "revoke", data: canonicalRequestJSON)
    }

    public func asDictionary() throws -> [String: Any] { try JSONSupport.object(from: canonicalRequestJSON) }
}

enum NativeTaskOperatorWire {
    static let identityKeys: Set<String> = ["schema_version", "request_id", "task_id", "capability_id", "project_id", "project_generation"]

    static func identity(requestID: UUID, taskID: UUID, capabilityID: UUID, projectID: ProjectID,
                         generation: ProjectGeneration) -> [String: Any] {
        ["schema_version": 1, "request_id": requestID.uuidString.lowercased(), "task_id": taskID.uuidString.lowercased(),
         "capability_id": capabilityID.uuidString.lowercased(), "project_id": projectID.description,
         "project_generation": generation.rawValue]
    }

    static func object(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw NativeTaskOperatorError.invalidRequest("body") }
        let integerKeys: Set<String> = ["schema_version", "project_generation", "profile_version", "expected_epoch", "epoch", "result_epoch",
            "maximum_inline_output_bytes", "maximum_calls", "maximum_result_bytes", "maximum_request_seconds"]
        do {
            let checked = try JSONSupport.validatingIntegerFields(in: data, maximumBytes: maximumBytes) {
                if $0.last == "prior_epoch" { return .optional }
                return $0.last.map(integerKeys.contains) == true ? .required : nil
            }
            guard let object = try JSONSerialization.jsonObject(with: checked) as? [String: Any] else {
                throw NativeTaskOperatorError.invalidRequest("body")
            }
            return object
        } catch { throw NativeTaskOperatorError.invalidRequest("body") }
    }

    static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional)) else {
            throw NativeTaskOperatorError.invalidRequest("fields")
        }
    }
    static func string(_ object: [String: Any], _ key: String, maximum: Int) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty, value.utf8.count <= maximum,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.contains("\0") else {
            throw NativeTaskOperatorError.invalidRequest(key)
        }
        return value
    }
    static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
        let value = try string(object, key, maximum: 36)
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw NativeTaskOperatorError.invalidRequest(key) }
        return id
    }
    static func hash(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key, maximum: 64)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NativeTaskOperatorError.invalidRequest(key)
        }
        return value
    }
    static func integer(_ object: [String: Any], _ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = JSONSupport.exactInteger(object[key]), range.contains(value) else { throw NativeTaskOperatorError.invalidRequest(key) }
        return value
    }
    static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw NativeTaskOperatorError.invalidRequest(key) }
        return value.boolValue
    }
    static func strings(_ object: [String: Any], _ key: String, maximumCount: Int, maximumBytes: Int) throws -> [String] {
        guard let values = object[key] as? [String], (1...maximumCount).contains(values.count), Set(values).count == values.count else {
            throw NativeTaskOperatorError.invalidRequest(key)
        }
        for value in values { _ = try string([key: value], key, maximum: maximumBytes) }
        return values
    }
    static func date(_ object: [String: Any], _ key: String) throws -> String {
        let value = try string(object, key, maximum: 32)
        guard let date = ISO8601.date(from: value), ISO8601.string(from: date) == value else { throw NativeTaskOperatorError.invalidRequest(key) }
        return value
    }
    static func version(_ object: [String: Any]) throws { _ = try integer(object, "schema_version", range: 1...1) }
    static func canonical(_ object: [String: Any], maximumBytes: Int) throws -> Data {
        let data = try ForgeJSONCanonicalizationV1.data(from: object)
        guard data.count <= maximumBytes else { throw NativeTaskOperatorError.invalidRequest("body") }
        return data
    }
    static func requestHash(action: String, data: Data) -> String {
        var bytes = Data("forge.continuity.task-command.v1\0\(action)\0".utf8)
        bytes.append(data)
        return JSONSupport.sha256Hex(bytes)
    }
}

// ContinuityTaskAuthorizationModels.swift
// Native-approved task assignments and exact source-call correlation.

import Foundation

enum ContinuityTaskAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case taskCorrelationRequired
    case authorityMismatch
    case revoked
    case assignmentConflict
    case capacityExceeded
    case invalidAssignment(String)
    case integrityFailure(String)

    var errorDescription: String? {
        switch self {
        case .taskCorrelationRequired: "A verified task correlation is required; an MCP process alone does not identify a conversation task"
        case .authorityMismatch: "The verified caller does not own this exact authorized task"
        case .revoked: "Task authorization has been permanently revoked"
        case .assignmentConflict: "The task already has a different immutable approved assignment"
        case .capacityExceeded: "The bounded task authorization store is full"
        case .invalidAssignment(let field): "Invalid approved task assignment: \(field)"
        case .integrityFailure(let reason): "Task authorization integrity failure: \(reason)"
        }
    }
}

/// Constructed by authenticated native assignment setup, never by decoding a
/// handoff's mission or a model tool request. The assignment bytes are retained;
/// their digest alone does not establish operator approval.
struct ContinuityTaskAssignment: Sendable, Equatable {
    static let maximumAssignmentBytes = 128 * 1_024
    static let maximumStoredBytes = 384 * 1_024

    let assignmentID: String
    let assignmentBytes: Data
    let documentSHA256: String
    let assignmentSHA256: String
    let mission: String
    let providerID: String
    let adapterID: String
    let modelKey: String
    let specification: AutonomousRunSpecification
    let authorizationScope: ToolAuthorizationScope

    init(assignmentID: String, assignmentBytes: Data, mission: String,
         providerID: String, adapterID: String, modelKey: String,
         specification: AutonomousRunSpecification, authorizationScope: ToolAuthorizationScope) throws {
        guard !assignmentBytes.isEmpty, assignmentBytes.count <= Self.maximumAssignmentBytes else {
            throw ContinuityTaskAuthorizationError.invalidAssignment("assignment bytes")
        }
        func bounded(_ value: String, maximum: Int, field: String) throws {
            guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.utf8.count <= maximum else {
                throw ContinuityTaskAuthorizationError.invalidAssignment(field)
            }
        }
        try bounded(assignmentID, maximum: 1_024, field: "assignment identifier")
        try bounded(mission, maximum: 65_536, field: "mission")
        try bounded(providerID, maximum: 256, field: "provider")
        try bounded(adapterID, maximum: 256, field: "adapter")
        try bounded(modelKey, maximum: 1_024, field: "model")
        guard (1...128).contains(specification.allowedTools.count),
              Set(specification.allowedTools).count == specification.allowedTools.count,
              Set(specification.allowedTools) == authorizationScope.allowedTools,
              !authorizationScope.allowedTools.contains("*"),
              (1...128).contains(specification.completionGates.count),
              Set(specification.completionGates).count == specification.completionGates.count,
              specification.completionGates.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              specification.work.pendingIntent == nil,
              specification.work.evidenceReferences.count <= 256,
              specification.work.metadata.count <= 256,
              try JSONEncoder().encode(specification).count <= 128 * 1_024 else {
            throw ContinuityTaskAuthorizationError.invalidAssignment("specification and tool scope")
        }
        let normalizedSpecification = AutonomousRunSpecification(allowedTools: specification.allowedTools.sorted(),
            completionGates: specification.completionGates, resourceProfile: specification.resourceProfile,
            work: specification.work)
        let digest = JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: Self.approvalObject(
            assignmentID: assignmentID, assignmentBytes: assignmentBytes, mission: mission,
            providerID: providerID, adapterID: adapterID, modelKey: modelKey,
            specification: normalizedSpecification, authorizationScope: authorizationScope)))
        _ = try ContinuityIngressAuthorization(projectID: ProjectID(), projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: assignmentID,
            assignmentSHA256: digest, authorizationScope: authorizationScope)
        self.assignmentID = assignmentID
        self.assignmentBytes = assignmentBytes
        self.documentSHA256 = JSONSupport.sha256Hex(assignmentBytes)
        self.assignmentSHA256 = digest
        self.mission = mission
        self.providerID = providerID
        self.adapterID = adapterID
        self.modelKey = modelKey
        self.specification = normalizedSpecification
        self.authorizationScope = authorizationScope
        guard try storedJSON().count <= Self.maximumStoredBytes else {
            throw ContinuityTaskAuthorizationError.invalidAssignment("stored assignment bytes")
        }
    }

    func storedJSON() throws -> Data {
        var object = try Self.approvalObject(assignmentID: assignmentID, assignmentBytes: assignmentBytes, mission: mission,
            providerID: providerID, adapterID: adapterID, modelKey: modelKey,
            specification: specification, authorizationScope: authorizationScope)
        object["assignment_sha256"] = assignmentSHA256
        return try ForgeJSONCanonicalizationV1.data(from: object)
    }

    /// The ingress digest binds the document and every approved execution field.
    /// It never hashes a wrapper containing its own digest.
    private static func approvalObject(assignmentID: String, assignmentBytes: Data, mission: String,
                                       providerID: String, adapterID: String, modelKey: String,
                                       specification: AutonomousRunSpecification,
                                       authorizationScope: ToolAuthorizationScope) throws -> [String: Any] {
        [
            "schema_version": 1, "assignment_id": assignmentID,
            "assignment_base64": assignmentBytes.base64EncodedString(), "document_sha256": JSONSupport.sha256Hex(assignmentBytes),
            "mission": mission, "provider_id": providerID, "adapter_id": adapterID, "model_key": modelKey,
            "specification": try JSONSerialization.jsonObject(with: JSONEncoder().encode(specification)),
            "authorization_scope": [
                "canonical_roots": authorizationScope.canonicalRoots.map(\.path),
                "writable_roots": authorizationScope.writableRoots.map(\.path),
                "allowed_tools": authorizationScope.allowedTools.sorted(),
                "network_allowed": authorizationScope.networkAllowed,
                "maximum_inline_output_bytes": authorizationScope.maximumInlineOutputBytes,
            ],
        ]
    }

    static func storedSnapshot(from data: Data) throws -> Self {
        guard data.count <= maximumStoredBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema_version", "assignment_id", "assignment_base64", "document_sha256", "assignment_sha256",
                                   "mission", "provider_id", "adapter_id", "model_key", "specification", "authorization_scope"],
              JSONSupport.exactInteger(object["schema_version"]) == 1,
              let assignmentID = object["assignment_id"] as? String,
              let encodedBytes = object["assignment_base64"] as? String,
              let bytes = Data(base64Encoded: encodedBytes),
              let digest = object["assignment_sha256"] as? String,
              let documentSHA = object["document_sha256"] as? String, JSONSupport.sha256Hex(bytes) == documentSHA,
              let mission = object["mission"] as? String, let provider = object["provider_id"] as? String,
              let adapter = object["adapter_id"] as? String, let model = object["model_key"] as? String,
              let specification = object["specification"] as? [String: Any],
              let scope = object["authorization_scope"] as? [String: Any],
              Set(scope.keys) == ["canonical_roots", "writable_roots", "allowed_tools", "network_allowed", "maximum_inline_output_bytes"],
              let roots = scope["canonical_roots"] as? [String], let writable = scope["writable_roots"] as? [String],
              let tools = scope["allowed_tools"] as? [String], let network = scope["network_allowed"] as? Bool,
              let maximum = JSONSupport.exactInteger(scope["maximum_inline_output_bytes"]) else {
            throw ContinuityTaskAuthorizationError.integrityFailure("malformed assignment snapshot")
        }
        let value = try Self(assignmentID: assignmentID, assignmentBytes: bytes, mission: mission,
            providerID: provider, adapterID: adapter, modelKey: model,
            specification: JSONDecoder().decode(AutonomousRunSpecification.self, from: JSONSerialization.data(withJSONObject: specification)),
            authorizationScope: ToolAuthorizationScope(canonicalRoots: roots.map { URL(fileURLWithPath: $0) },
                writableRoots: writable.map { URL(fileURLWithPath: $0) }, allowedTools: Set(tools),
                networkAllowed: network, maximumInlineOutputBytes: maximum))
        guard value.assignmentSHA256 == digest, try value.storedJSON() == data else {
            throw ContinuityTaskAuthorizationError.integrityFailure("noncanonical assignment snapshot")
        }
        return value
    }
}

enum ContinuityTaskAuthorizationState: String, Sendable, Equatable { case active, revoked }

struct ContinuityTaskAuthorizationRecord: Sendable, Equatable {
    let authorization: ContinuityIngressAuthorization
    let assignment: ContinuityTaskAssignment
    let state: ContinuityTaskAuthorizationState
    let revision: Int64
    let runID: RunID?
    let createdAt: String
    let revokedAt: String?
}

/// An opaque native in-memory correlation, never a Codable credential or a
/// model-supplied task identifier. The setup boundary has verified the task and
/// its specific caller binding. A transport client may carry several different
/// correlations; its process ID cannot select one on its own.
struct VerifiedContinuityTaskCorrelation: Sendable {
    let taskID: UUID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let sourceBindingID: UUID
    let callerBindingID: UUID
    let callerOwner: ProjectBindingOwner
    let callerContext: ToolInvocationContext
    let authorizationSHA256: String
    let nativeCredential: NativeTaskCapabilityCredential?

    private init(record: ContinuityTaskAuthorizationRecord, caller: ProjectContextBinding,
                 context: ToolInvocationContext, nativeCredential: NativeTaskCapabilityCredential? = nil) throws {
        self.nativeCredential = nativeCredential
        taskID = record.authorization.taskID
        projectID = record.authorization.projectID
        projectGeneration = record.authorization.projectGeneration
        sourceBindingID = record.authorization.sourceBindingID
        callerBindingID = caller.bindingID
        callerOwner = caller.owner
        callerContext = context
        authorizationSHA256 = JSONSupport.sha256Hex(try record.authorization.encodedJSON())
    }

    /// Called only after the repository's authenticated native setup transaction
    /// has validated its live task and caller rows. There is no wire decoder.
    static func nativeCapabilityResult(record: ContinuityTaskAuthorizationRecord, caller: ProjectContextBinding,
        context: ToolInvocationContext, credential: NativeTaskCapabilityCredential) throws -> Self {
        try Self(record: record, caller: caller, context: context, nativeCredential: credential)
    }

    static func nativeSetupResult(record: ContinuityTaskAuthorizationRecord, caller: ProjectContextBinding,
                                  context: ToolInvocationContext) throws -> Self {
        try Self(record: record, caller: caller, context: context)
    }
}

struct AuthorizedContinuityTaskSetup: Sendable {
    let record: ContinuityTaskAuthorizationRecord
    let correlation: VerifiedContinuityTaskCorrelation
}

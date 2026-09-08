// Versioned operator budget preferences. Capacity is resolved from the loaded
// provider at execution boundaries; stored preferences never authorize a load.
import Foundation

public enum BudgetContextMode: String, Codable, Sendable { case auto, manual }

public struct BudgetContextPolicy: Codable, Sendable, Equatable {
    public let mode: BudgetContextMode
    public let maxContextTokens: Int
    public let responseReserveTokens: Int?
    public let futureToolReserveTokens: Int?
    public let handoffReserveTokens: Int?
    public let recoveryReserveTokens: Int?
    public let safetyReserveTokens: Int?
    public let checkpointRatio: Double
    public let rolloverRatio: Double
    public let emergencyRatio: Double

    public init(mode: BudgetContextMode = .auto, maxContextTokens: Int = 32_768,
                responseReserveTokens: Int? = nil, futureToolReserveTokens: Int? = nil,
                handoffReserveTokens: Int? = nil, recoveryReserveTokens: Int? = nil,
                safetyReserveTokens: Int? = nil, checkpointRatio: Double = 0.75,
                rolloverRatio: Double = 0.85, emergencyRatio: Double = 0.95) {
        self.mode = mode; self.maxContextTokens = maxContextTokens
        self.responseReserveTokens = responseReserveTokens; self.futureToolReserveTokens = futureToolReserveTokens
        self.handoffReserveTokens = handoffReserveTokens; self.recoveryReserveTokens = recoveryReserveTokens
        self.safetyReserveTokens = safetyReserveTokens; self.checkpointRatio = checkpointRatio
        self.rolloverRatio = rolloverRatio; self.emergencyRatio = emergencyRatio
    }

    public func validated() throws -> Self {
        try BudgetPolicyCoding.range(maxContextTokens, 512...ContextCapacityResolver.maximumSupportedCapacity, "context.max_context_tokens")
        let reserves = [("response_reserve_tokens", responseReserveTokens), ("future_tool_reserve_tokens", futureToolReserveTokens),
                        ("handoff_reserve_tokens", handoffReserveTokens), ("recovery_reserve_tokens", recoveryReserveTokens),
                        ("safety_reserve_tokens", safetyReserveTokens)]
        var total = 0
        for (field, value) in reserves {
            if let value {
                try BudgetPolicyCoding.range(value, 0...ContextCapacityResolver.maximumSupportedCapacity, "context." + field)
                total += value // Five individually bounded capacity-sized terms cannot overflow Int.
            }
        }
        guard mode != .manual || total < maxContextTokens else {
            throw ManagerSettingsValidationError(field: "context.reserves", reason: "reserves_must_leave_input_capacity", permittedRange: "0..<\(maxContextTokens)")
        }
        guard checkpointRatio.isFinite, rolloverRatio.isFinite, emergencyRatio.isFinite,
              checkpointRatio > 0, checkpointRatio < rolloverRatio,
              rolloverRatio < emergencyRatio, emergencyRatio <= 1 else {
            throw ManagerSettingsValidationError(field: "context.thresholds", reason: "expected_ordered_admitted_total_ratios", permittedRange: "0 < checkpoint < rollover < emergency <= 1")
        }
        return self
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case maxContextTokens = "max_context_tokens"
        case responseReserveTokens = "response_reserve_tokens"
        case futureToolReserveTokens = "future_tool_reserve_tokens"
        case handoffReserveTokens = "handoff_reserve_tokens"
        case recoveryReserveTokens = "recovery_reserve_tokens"
        case safetyReserveTokens = "safety_reserve_tokens"
        case checkpointRatio = "checkpoint_ratio"
        case rolloverRatio = "rollover_ratio"
        case emergencyRatio = "emergency_ratio"
    }

    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try c.decode(BudgetContextMode.self, forKey: .mode),
                  maxContextTokens: try BudgetPolicyCoding.integer(c, .maxContextTokens),
                  responseReserveTokens: try BudgetPolicyCoding.optionalInteger(c, .responseReserveTokens),
                  futureToolReserveTokens: try BudgetPolicyCoding.optionalInteger(c, .futureToolReserveTokens),
                  handoffReserveTokens: try BudgetPolicyCoding.optionalInteger(c, .handoffReserveTokens),
                  recoveryReserveTokens: try BudgetPolicyCoding.optionalInteger(c, .recoveryReserveTokens),
                  safetyReserveTokens: try BudgetPolicyCoding.optionalInteger(c, .safetyReserveTokens),
                  checkpointRatio: try c.decode(Double.self, forKey: .checkpointRatio),
                  rolloverRatio: try c.decode(Double.self, forKey: .rolloverRatio),
                  emergencyRatio: try c.decode(Double.self, forKey: .emergencyRatio))
        _ = try validated()
    }
}

public struct BudgetToolPolicy: Codable, Sendable, Equatable {
    public let callsPerTurn: Int
    public let callsPerSession: Int
    public let callsPerRun: Int
    public let maxInFlight: Int
    public let maxResultBytes: Int
    public let maxRetainedResultTokens: Int
    public let recoveryCallsPerRollover: Int

    public init(callsPerTurn: Int = 8, callsPerSession: Int = 64, callsPerRun: Int = 512,
                maxInFlight: Int = 2, maxResultBytes: Int = 65_536,
                maxRetainedResultTokens: Int = 4_096, recoveryCallsPerRollover: Int = 4) {
        self.callsPerTurn = callsPerTurn; self.callsPerSession = callsPerSession; self.callsPerRun = callsPerRun
        self.maxInFlight = maxInFlight; self.maxResultBytes = maxResultBytes
        self.maxRetainedResultTokens = maxRetainedResultTokens; self.recoveryCallsPerRollover = recoveryCallsPerRollover
    }

    public func validated() throws -> Self {
        for (field, value) in [("calls_per_turn", callsPerTurn), ("calls_per_session", callsPerSession), ("calls_per_run", callsPerRun)] {
            try BudgetPolicyCoding.range(value, 1...1_000_000, "tools." + field)
        }
        guard callsPerTurn <= callsPerSession, callsPerSession <= callsPerRun else {
            throw ManagerSettingsValidationError(field: "tools.calls_per_run", reason: "expected_turn_not_above_session_not_above_run")
        }
        try BudgetPolicyCoding.range(maxInFlight, 1...min(64, callsPerTurn), "tools.max_in_flight")
        try BudgetPolicyCoding.range(maxResultBytes, 1...16_777_216, "tools.max_result_bytes")
        try BudgetPolicyCoding.range(maxRetainedResultTokens, 1...1_048_576, "tools.max_retained_result_tokens")
        try BudgetPolicyCoding.range(recoveryCallsPerRollover, 1...32, "tools.recovery_calls_per_rollover")
        return self
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case callsPerTurn = "calls_per_turn", callsPerSession = "calls_per_session", callsPerRun = "calls_per_run"
        case maxInFlight = "max_in_flight", maxResultBytes = "max_result_bytes"
        case maxRetainedResultTokens = "max_retained_result_tokens", recoveryCallsPerRollover = "recovery_calls_per_rollover"
    }

    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(callsPerTurn: try BudgetPolicyCoding.integer(c, .callsPerTurn),
                  callsPerSession: try BudgetPolicyCoding.integer(c, .callsPerSession),
                  callsPerRun: try BudgetPolicyCoding.integer(c, .callsPerRun),
                  maxInFlight: try BudgetPolicyCoding.integer(c, .maxInFlight),
                  maxResultBytes: try BudgetPolicyCoding.integer(c, .maxResultBytes),
                  maxRetainedResultTokens: try BudgetPolicyCoding.integer(c, .maxRetainedResultTokens),
                  recoveryCallsPerRollover: try BudgetPolicyCoding.integer(c, .recoveryCallsPerRollover))
        _ = try validated()
    }
}

public struct BudgetPolicy: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let `default` = BudgetPolicy()
    public let schemaVersion: Int
    public let context: BudgetContextPolicy
    public let tools: BudgetToolPolicy
    /// Only an authenticated operator update can enable handoff enrollment.
    public let automaticHandoffEnabled: Bool

    public init(schemaVersion: Int = currentSchemaVersion, context: BudgetContextPolicy = .init(),
                tools: BudgetToolPolicy = .init(), automaticHandoffEnabled: Bool = false) {
        self.schemaVersion = schemaVersion; self.context = context; self.tools = tools
        self.automaticHandoffEnabled = automaticHandoffEnabled
    }
    public func validated() throws -> Self {
        try BudgetPolicyCoding.range(schemaVersion, 1...1, "schema_version")
        _ = try context.validated(); _ = try tools.validated()
        return self
    }
    /// Use this at raw-data boundaries. Generic Codable decoders cannot expose
    /// the original numeric lexeme and therefore cannot prove decimal exactness.
    public static func decode(data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: BudgetPolicyCoding.validateJSON(data)).validated()
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", context, tools, automaticHandoffEnabled = "automatic_handoff_enabled"
    }
    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try BudgetPolicyCoding.integer(c, .schemaVersion),
                  context: try c.decode(BudgetContextPolicy.self, forKey: .context),
                  tools: try c.decode(BudgetToolPolicy.self, forKey: .tools),
                  automaticHandoffEnabled: try c.decode(Bool.self, forKey: .automaticHandoffEnabled))
        _ = try validated()
    }
}

public struct BudgetPolicyScope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case globalDefault = "global_default", projectOverride = "project_override" }
    public let kind: Kind
    public let projectID: String?
    public let projectGeneration: Int?
    public static let globalDefault = BudgetPolicyScope(kind: .globalDefault)
    public init(kind: Kind, projectID: String? = nil, projectGeneration: Int? = nil) {
        self.kind = kind; self.projectID = projectID; self.projectGeneration = projectGeneration
    }
    public func validated() throws -> Self {
        switch kind {
        case .globalDefault:
            guard projectID == nil, projectGeneration == nil else {
                throw ManagerSettingsValidationError(field: "scope", reason: "global_scope_has_no_project")
            }
        case .projectOverride:
            guard let projectID, let id = UUID(uuidString: projectID), id.uuidString.lowercased() == projectID,
                  let projectGeneration, projectGeneration > 0 else {
                throw ManagerSettingsValidationError(field: "scope", reason: "expected_exact_project_and_generation")
            }
        }
        return self
    }
    public var key: String { "\(projectID ?? "global"):\(projectGeneration ?? 0)" }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, projectID = "project_id", projectGeneration = "project_generation"
    }
    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), projectID: try c.decodeIfPresent(String.self, forKey: .projectID),
                  projectGeneration: try BudgetPolicyCoding.optionalInteger(c, .projectGeneration))
        _ = try validated()
    }
}

/// A nil project policy is a revision-bearing inheritance tombstone, preventing
/// a stale editor from overwriting a reset as if the scope had never existed.
public struct BudgetProjectPolicy: Codable, Sendable, Equatable {
    public let scope: BudgetPolicyScope
    public let revision: Int
    public let policy: BudgetPolicy?
    public init(scope: BudgetPolicyScope, revision: Int, policy: BudgetPolicy?) {
        self.scope = scope; self.revision = revision; self.policy = policy
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case scope, revision, policy }
    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scope: try c.decode(BudgetPolicyScope.self, forKey: .scope), revision: try BudgetPolicyCoding.integer(c, .revision),
                  policy: try c.decodeIfPresent(BudgetPolicy.self, forKey: .policy))
    }
}

public struct BudgetPolicyState: Codable, Sendable, Equatable {
    public static let maximumProjectOverrides = 256
    public let schemaVersion: Int
    public let globalRevision: Int
    public let globalPolicy: BudgetPolicy
    public let projectOverrides: [String: BudgetProjectPolicy]
    public static let `default` = BudgetPolicyState()
    public init(schemaVersion: Int = 1, globalRevision: Int = 1, globalPolicy: BudgetPolicy = .default,
                projectOverrides: [String: BudgetProjectPolicy] = [:]) {
        self.schemaVersion = schemaVersion; self.globalRevision = globalRevision
        self.globalPolicy = globalPolicy; self.projectOverrides = projectOverrides
    }
    public func validated() throws -> Self {
        try BudgetPolicyCoding.range(schemaVersion, 1...1, "budget_policy.schema_version")
        try BudgetPolicyCoding.range(globalRevision, 1...(Int.max - 1), "budget_policy.global_revision")
        _ = try globalPolicy.validated()
        guard projectOverrides.count <= Self.maximumProjectOverrides else {
            throw ManagerSettingsValidationError(field: "budget_policy.project_overrides", reason: "too_many_project_scopes")
        }
        for (key, value) in projectOverrides {
            _ = try value.scope.validated()
            guard value.scope.kind == .projectOverride, key == value.scope.key else {
                throw ManagerSettingsValidationError(field: "budget_policy.project_overrides", reason: "scope_key_mismatch")
            }
            try BudgetPolicyCoding.range(value.revision, 1...(Int.max - 1), "budget_policy.project_revision")
            _ = try value.policy?.validated()
        }
        return self
    }
    public func resolve(_ scope: BudgetPolicyScope) throws -> BudgetPolicySelection {
        _ = try validated(); _ = try scope.validated()
        let project = scope.kind == .projectOverride ? projectOverrides[scope.key] : nil
        return BudgetPolicySelection(scope: scope, revision: scope.kind == .globalDefault ? globalRevision : (project?.revision ?? 0),
                                     globalRevision: globalRevision, inherited: scope.kind == .projectOverride && project?.policy == nil,
                                     policy: project?.policy ?? globalPolicy)
    }
    public static func decode(data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: BudgetPolicyCoding.validateJSON(data)).validated()
    }

    /// Call before parsing persisted config bytes into Foundation objects. Keep
    /// the original bytes for backups and migration hashes; parse the returned
    /// bytes, whose exact count tokens have been normalized without rounding.
    public static func validateConfigurationJSON(_ data: Data) throws -> Data {
        try BudgetPolicyCoding.validateJSON(data, inside: { $0.first == "budget_policy" })
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", globalRevision = "global_revision", globalPolicy = "global_policy", projectOverrides = "project_overrides"
    }
    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try BudgetPolicyCoding.integer(c, .schemaVersion), globalRevision: try BudgetPolicyCoding.integer(c, .globalRevision),
                  globalPolicy: try c.decode(BudgetPolicy.self, forKey: .globalPolicy),
                  projectOverrides: try c.decode([String: BudgetProjectPolicy].self, forKey: .projectOverrides))
        _ = try validated()
    }
}

public struct BudgetPolicySelection: Codable, Sendable, Equatable {
    public let scope: BudgetPolicyScope
    public let revision: Int
    public let globalRevision: Int
    public let inherited: Bool
    public let policy: BudgetPolicy
    public var policySource: String { inherited || scope.kind == .globalDefault ? "global_default" : "project_override" }
    private enum CodingKeys: String, CodingKey {
        case scope, revision, globalRevision = "global_revision", inherited, policy
    }
}

public struct BudgetPolicyUpdate: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case set, reset, inherit }
    public let scope: BudgetPolicyScope
    public let expectedRevision: Int
    public let expectedGlobalRevision: Int
    public let operation: Operation
    public let policy: BudgetPolicy?
    public init(scope: BudgetPolicyScope, expectedRevision: Int, expectedGlobalRevision: Int,
                operation: Operation, policy: BudgetPolicy? = nil) {
        self.scope = scope; self.expectedRevision = expectedRevision; self.expectedGlobalRevision = expectedGlobalRevision
        self.operation = operation; self.policy = policy
    }
    public func validated() throws -> Self {
        _ = try scope.validated()
        try BudgetPolicyCoding.range(expectedRevision, 0...(Int.max - 1), "expected_revision")
        try BudgetPolicyCoding.range(expectedGlobalRevision, 1...(Int.max - 1), "expected_global_revision")
        guard (operation == .set) == (policy != nil), operation != .inherit || scope.kind == .projectOverride else {
            throw ManagerSettingsValidationError(field: "operation", reason: "invalid_policy_operation")
        }
        _ = try policy?.validated()
        return self
    }
    /// Adapter for already typed in-memory values. Raw JSON callers must first
    /// use the Data entrypoint; a rounded NSNumber cannot reveal lost digits.
    public static func decode(dictionary: [String: Any]) throws -> Self {
        do {
            return try decode(data: JSONSupport.data(from: dictionary))
        } catch let error as ManagerSettingsValidationError { throw error }
        catch {
            throw ManagerSettingsValidationError(field: "budget_update", reason: "malformed_policy_update")
        }
    }
    public static func decode(data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: BudgetPolicyCoding.validateJSON(data, maximumBytes: 65_536)).validated()
    }

    /// The raw HTTP envelope must be checked before JSONSerialization creates
    /// NSNumber values. Legacy integer strings remain supported in their prior
    /// fields, while new budget counts require JSON numbers.
    public static func validateSettingsJSON(_ data: Data) throws -> Data {
        let legacyFields: Set<String> = [
            "dashboard.port", "dashboard.refresh_interval_sec", "manager.watchdog_interval_sec",
            "sessions.idle_ttl_sec", "shell.default_timeout_sec",
        ]
        do {
            return try JSONSupport.validatingIntegerFields(in: data, maximumBytes: 65_536) { path in
                let patchPath = path.first == "settings" ? Array(path.dropFirst()) : path
                if patchPath.first == "budget_update" { return BudgetPolicyCoding.integerRequirement(path) }
                return legacyFields.contains(patchPath.joined(separator: ".")) ? .legacyStringCompatible : nil
            }
        } catch let error as ManagerSettingsValidationError where error.field.hasPrefix("settings.") {
            // The optional HTTP envelope is not part of a setting's public key.
            throw ManagerSettingsValidationError(field: String(error.field.dropFirst("settings.".count)),
                reason: error.reason, permittedRange: error.permittedRange)
        }
    }
    public func asDictionary() throws -> [String: Any] {
        try JSONSupport.object(from: JSONEncoder().encode(validated()))
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope, expectedRevision = "expected_revision", expectedGlobalRevision = "expected_global_revision", operation, policy
    }
    public init(from decoder: Decoder) throws {
        try BudgetPolicyCoding.keys(decoder, CodingKeys.allCases)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scope: try c.decode(BudgetPolicyScope.self, forKey: .scope), expectedRevision: try BudgetPolicyCoding.integer(c, .expectedRevision),
                  expectedGlobalRevision: try BudgetPolicyCoding.integer(c, .expectedGlobalRevision), operation: try c.decode(Operation.self, forKey: .operation),
                  policy: try c.decodeIfPresent(BudgetPolicy.self, forKey: .policy))
        _ = try validated()
    }
}

public struct BudgetPolicyConflict: Error, LocalizedError, Sendable {
    public let current: BudgetPolicySelection
    public var errorDescription: String? { "Budget policy changed in another editor. Reload the current policy before saving." }
}

private enum BudgetPolicyCoding {
    private static let integerFields: Set<String> = [
        "schema_version", "max_context_tokens", "response_reserve_tokens", "future_tool_reserve_tokens",
        "handoff_reserve_tokens", "recovery_reserve_tokens", "safety_reserve_tokens",
        "calls_per_turn", "calls_per_session", "calls_per_run", "max_in_flight", "max_result_bytes",
        "max_retained_result_tokens", "recovery_calls_per_rollover", "project_generation", "revision",
        "global_revision", "expected_revision", "expected_global_revision",
    ]
    private static let optionalIntegerFields: Set<String> = [
        "response_reserve_tokens", "future_tool_reserve_tokens", "handoff_reserve_tokens",
        "recovery_reserve_tokens", "safety_reserve_tokens", "project_generation",
    ]
    static func integerRequirement(_ path: [String]) -> JSONSupport.IntegerFieldRequirement? {
        guard let key = path.last, integerFields.contains(key) else { return nil }
        return optionalIntegerFields.contains(key) ? .optional : .required
    }
    static func validateJSON(_ data: Data, maximumBytes: Int = 2 * 1_048_576,
                             inside: ([String]) -> Bool = { _ in true }) throws -> Data {
        try JSONSupport.validatingIntegerFields(in: data, maximumBytes: maximumBytes) { path in
            inside(path) ? integerRequirement(path) : nil
        }
    }
    private struct Key: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys<K: CodingKey>(_ decoder: Decoder, _ allowed: [K]) throws {
        let c = try decoder.container(keyedBy: Key.self); let names = Set(allowed.map(\.stringValue))
        for key in c.allKeys where !names.contains(key.stringValue) {
            throw ManagerSettingsValidationError(field: (decoder.codingPath + [key]).map(\.stringValue).joined(separator: "."), reason: "unknown_field")
        }
    }
    static func integer<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Int {
        // Raw data entrypoints validate and normalize count tokens first.
        // Decimal adds a secondary guard for in-memory Codable callers, but its
        // finite precision alone cannot establish exactness of arbitrary JSON.
        guard let decimal = try? c.decode(Decimal.self, forKey: key),
              let value = Int(NSDecimalNumber(decimal: decimal).stringValue) else {
            throw ManagerSettingsValidationError(field: (c.codingPath + [key]).map(\.stringValue).joined(separator: "."), reason: "expected_exact_integer")
        }
        return value
    }
    static func optionalInteger<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Int? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        return try integer(c, key)
    }
    static func range(_ value: Int, _ bounds: ClosedRange<Int>, _ field: String) throws {
        guard bounds.contains(value) else {
            throw ManagerSettingsValidationError(field: field, reason: "outside_supported_range", permittedRange: "\(bounds.lowerBound)...\(bounds.upperBound)")
        }
    }
}

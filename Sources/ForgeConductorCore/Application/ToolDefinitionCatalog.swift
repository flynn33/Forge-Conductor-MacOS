// ToolDefinitionCatalog.swift
// Owns the canonical typed tool definitions shared by MCP and managed provider turns.

import Foundation

public struct CanonicalToolDefinition: Sendable, Equatable {
    public static let maximumNameBytes = 256
    public static let maximumDescriptionBytes = 4 * 1_024
    public static let maximumSchemaBytes = 256 * 1_024

    public let name: String
    public let description: String
    public let inputSchemaJSON: Data
    public let strict: Bool

    public init(
        name: String,
        description: String,
        inputSchema: [String: Any]
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName == name, !name.isEmpty,
              name.utf8.count <= Self.maximumNameBytes else {
            throw ToolDefinitionCatalogError.invalidName(name)
        }
        guard normalizedDescription == description, !description.isEmpty,
              description.utf8.count <= Self.maximumDescriptionBytes else {
            throw ToolDefinitionCatalogError.invalidDescription(name)
        }
        guard inputSchema["type"] as? String == "object",
              JSONSerialization.isValidJSONObject(inputSchema) else {
            throw ToolDefinitionCatalogError.invalidSchema(name)
        }
        let schemaData = try JSONSerialization.data(
            withJSONObject: inputSchema,
            options: [.sortedKeys]
        )
        guard schemaData.count <= Self.maximumSchemaBytes else {
            throw ToolDefinitionCatalogError.invalidSchema(name)
        }
        self.name = name
        self.description = description
        self.inputSchemaJSON = schemaData
        self.strict = inputSchema["additionalProperties"] as? Bool == false
    }

    public func inputSchemaObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: inputSchemaJSON) as? [String: Any],
              object["type"] as? String == "object" else {
            throw ToolDefinitionCatalogError.invalidSchema(name)
        }
        return object
    }

    public func mcpDescriptor() throws -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": try inputSchemaObject(),
        ]
    }

    public func providerDefinitionJSON() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try providerDefinitionObject(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    fileprivate func providerDefinitionObject() throws -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": try inputSchemaObject(),
            "strict": strict,
        ]
    }
}

public struct ToolDefinitionCatalog: Sendable, Equatable {
    public static let maximumDefinitions = 512
    static let controlPlaneOnlyToolNames = Set(ContinuityControlToolName.allCases.map(\.rawValue))

    public let definitions: [CanonicalToolDefinition]
    public let canonicalJSON: Data
    public let canonicalSHA256: String

    public init(
        toolNames: [String],
        definitions suppliedDefinitions: [CanonicalToolDefinition]
    ) throws {
        guard !toolNames.isEmpty, toolNames.count <= Self.maximumDefinitions,
              toolNames.count == Set(toolNames).count else {
            throw ToolDefinitionCatalogError.invalidToolSet
        }
        guard suppliedDefinitions.count <= Self.maximumDefinitions else {
            throw ToolDefinitionCatalogError.invalidToolSet
        }
        let suppliedNames = suppliedDefinitions.map(\.name)
        guard suppliedNames.count == Set(suppliedNames).count else {
            throw ToolDefinitionCatalogError.duplicateDefinition
        }
        let registered = Set(toolNames)
        let supplied = Set(suppliedNames)
        let missing = registered.subtracting(supplied).sorted()
        guard missing.isEmpty else {
            throw ToolDefinitionCatalogError.missingDefinitions(missing)
        }
        let stale = supplied.subtracting(registered).sorted()
        guard stale.isEmpty else {
            throw ToolDefinitionCatalogError.staleDefinitions(stale)
        }
        let ordered = suppliedDefinitions.sorted { $0.name < $1.name }
        let canonical = try Self.encode(ordered)
        self.definitions = ordered
        self.canonicalJSON = canonical
        self.canonicalSHA256 = JSONSupport.sha256Hex(canonical)
    }

    /// Builds the exact production catalog. Every registered tool must have both a
    /// description and an object-shaped schema; there is no generic fallback.
    public static func production(toolNames: [String]) throws -> ToolDefinitionCatalog {
        let definitions = try toolNames.map { name in
            guard let description = ProductionToolDefinitionSource.description(for: name),
                  let schema = ProductionToolDefinitionSource.schema(for: name) else {
                throw ToolDefinitionCatalogError.missingDefinitions([name])
            }
            return try CanonicalToolDefinition(
                name: name,
                description: description,
                inputSchema: ContinuityControlToolName(rawValue: name) == nil
                    ? schemaWithSharedInvocationControls(schema) : schema
            )
        }
        return try ToolDefinitionCatalog(toolNames: toolNames, definitions: definitions)
    }

    public func definition(named name: String) -> CanonicalToolDefinition? {
        definitions.first { $0.name == name }
    }

    /// Returns the canonical definitions that a managed provider turn is permitted to
    /// expose. A wildcard follows ToolAuthorizationScope semantics and selects all tools.
    public func definitions(
        allowedToolNames: Set<String>
    ) throws -> [CanonicalToolDefinition] {
        if allowedToolNames.contains("*") { return definitions }
        let known = Set(definitions.map(\.name))
        let unknown = allowedToolNames.subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw ToolDefinitionCatalogError.unregisteredAllowedTools(unknown)
        }
        let expanded = ToolGrantSemantics.expanded(allowedToolNames)
        return definitions.filter { expanded.contains($0.name) }
    }

    public func canonicalJSON(allowedToolNames: Set<String>) throws -> Data {
        try Self.encode(definitions(allowedToolNames: allowedToolNames))
    }

    /// Produces one canonical function-tool object per allowed tool for
    /// `ProviderRootRequest` and `ProviderContinuationRequest`.
    public func providerToolDefinitions(
        allowedToolNames: Set<String>
    ) throws -> [Data] {
        let controls = allowedToolNames.intersection(Self.controlPlaneOnlyToolNames).sorted()
        guard controls.isEmpty else {
            throw ToolDefinitionCatalogError.controlPlaneOnlyTools(controls)
        }
        return try definitions(allowedToolNames: allowedToolNames).filter {
            !Self.controlPlaneOnlyToolNames.contains($0.name)
        }.map {
            try $0.providerDefinitionJSON()
        }
    }

    public func mcpDescriptors() throws -> [[String: Any]] {
        try definitions.map { try $0.mcpDescriptor() }
    }

    private static func schemaWithSharedInvocationControls(
        _ suppliedSchema: [String: Any]
    ) -> [String: Any] {
        var schema = suppliedSchema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        // The shared transport owns this field. Replace pack-local placeholder
        // schemas so every advertised tool has the same accepted range.
        properties["deadline_ms"] = [
            "type": "integer",
            "minimum": 1,
            "maximum": ToolRouter.maximumRequestedDeadlineMilliseconds,
            "description": "Optional total tool-call deadline in milliseconds.",
        ] as [String: Any]
        schema["properties"] = properties
        return schema
    }

    private static func encode(_ definitions: [CanonicalToolDefinition]) throws -> Data {
        let payload = try definitions.map { try $0.providerDefinitionObject() }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

public enum ToolDefinitionCatalogError: Error, LocalizedError, Sendable, Equatable {
    case invalidToolSet
    case duplicateDefinition
    case invalidName(String)
    case invalidDescription(String)
    case invalidSchema(String)
    case missingDefinitions([String])
    case staleDefinitions([String])
    case unregisteredAllowedTools([String])
    case controlPlaneOnlyTools([String])

    public var errorDescription: String? {
        switch self {
        case .invalidToolSet:
            "Registered tool names must be unique, nonempty, and bounded"
        case .duplicateDefinition:
            "Canonical tool definitions contain duplicate names"
        case .invalidName(let name):
            "Tool definition has an invalid name: \(name)"
        case .invalidDescription(let name):
            "Tool definition has an invalid description: \(name)"
        case .invalidSchema(let name):
            "Tool definition has an invalid input schema: \(name)"
        case .missingDefinitions(let names):
            "Registered tools are missing canonical definitions: \(names.joined(separator: ","))"
        case .staleDefinitions(let names):
            "Canonical definitions name unregistered tools: \(names.joined(separator: ","))"
        case .unregisteredAllowedTools(let names):
            "Allowed tool set contains unregistered tools: \(names.joined(separator: ","))"
        case .controlPlaneOnlyTools(let names):
            "Native task controls cannot be granted to managed provider work: \(names.joined(separator: ","))"
        }
    }
}

public enum ManagerToolSelectionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case recommended
    case allEligible = "all_eligible"
    case explicit
}

public enum ManagerToolCategory: String, Codable, Sendable, Equatable, CaseIterable {
    case files
    case search
    case sourceControl = "source_control"
    case commands
    case projectMemory = "project_memory"
    case continuity
    case agents
    case documents
    case runtime
    case other

    public var displayName: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .sourceControl: "Source control"
        case .commands: "Build and commands"
        case .projectMemory: "Project memory"
        case .continuity: "Continuity"
        case .agents: "Agent support"
        case .documents: "Documents"
        case .runtime: "Runtime jobs"
        case .other: "Other"
        }
    }

    static func classify(_ toolID: String) -> Self {
        if toolID.hasPrefix("fs_") { return .files }
        if toolID.hasPrefix("search_") { return .search }
        if toolID.hasPrefix("git_") { return .sourceControl }
        if toolID == "shell_exec" { return .commands }
        if toolID.hasPrefix("project_memory.") || toolID.hasPrefix("memory_") {
            return .projectMemory
        }
        if toolID.hasPrefix("continuity.") || toolID.hasPrefix("session_")
            || toolID.hasPrefix("context_") {
            return .continuity
        }
        if toolID.hasPrefix("agent_") || toolID == "forge_status" { return .agents }
        if toolID.hasPrefix("pdf_") { return .documents }
        if toolID.hasPrefix("runtime_") { return .runtime }
        return .other
    }
}

public struct ManagerToolCatalogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let category: ManagerToolCategory
    public let categoryDisplayName: String
    public let recommended: Bool
    public let available: Bool
    public let unavailableReason: String?
    public let highImpact: Bool

    enum CodingKeys: String, CodingKey {
        case id, description, category, recommended, available
        case displayName = "display_name"
        case categoryDisplayName = "category_display_name"
        case unavailableReason = "unavailable_reason"
        case highImpact = "high_impact"
    }
}

public struct ManagerToolPermissionSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let projectGeneration: UInt64
    public let preferenceRevision: UInt64
    public let catalogRevision: String
    public let selectionMode: ManagerToolSelectionMode
    /// User intent. Explicit selections remain here even while a tool is unavailable.
    public let selectedToolIDs: [String]
    /// Exact currently registered and available grant used when a run is prepared.
    public let effectiveToolIDs: [String]
    public let tools: [ManagerToolCatalogEntry]
    public let updatedAt: String?

    public var selectedCount: Int { selectedToolIDs.count }
    public var effectiveCount: Int { effectiveToolIDs.count }
    public var availableCount: Int { tools.lazy.filter(\.available).count }

    enum CodingKeys: String, CodingKey {
        case tools
        case schemaVersion = "schema_version"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case preferenceRevision = "preference_revision"
        case catalogRevision = "catalog_revision"
        case selectionMode = "selection_mode"
        case selectedToolIDs = "selected_tool_ids"
        case effectiveToolIDs = "effective_tool_ids"
        case updatedAt = "updated_at"
    }

    public func asDictionary() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolPermissionStoreError.invalidPersistence
        }
        return object
    }
}

public struct ManagerToolPermissionUpdate: Codable, Sendable, Equatable {
    public let projectID: String
    public let projectGeneration: UInt64
    public let expectedPreferenceRevision: UInt64
    public let selectionMode: ManagerToolSelectionMode
    public let selectedToolIDs: [String]

    public init(
        projectID: String,
        projectGeneration: UInt64,
        expectedPreferenceRevision: UInt64,
        selectionMode: ManagerToolSelectionMode,
        selectedToolIDs: [String]
    ) {
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.expectedPreferenceRevision = expectedPreferenceRevision
        self.selectionMode = selectionMode
        self.selectedToolIDs = selectedToolIDs
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case expectedPreferenceRevision = "expected_preference_revision"
        case selectionMode = "selection_mode"
        case selectedToolIDs = "selected_tool_ids"
    }
}

public enum ToolPermissionStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidPersistence
    case invalidSelection
    case staleRevision(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidPersistence:
            "Project tool preferences are unavailable or invalid"
        case .invalidSelection:
            "Tool selections must be unique bounded registered identifiers"
        case .staleRevision(let expected, let actual):
            "Tool preferences changed (expected revision \(expected), current revision \(actual))"
        }
    }
}

/// One owner-only durable store for project defaults. Run preparation resolves
/// these defaults against the live catalog and freezes the exact resulting grant.
final class ProjectToolPermissionStore: @unchecked Sendable {
    private struct Record: Codable, Sendable, Equatable {
        let revision: UInt64
        let selectionMode: ManagerToolSelectionMode
        let selectedToolIDs: [String]
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case revision
            case selectionMode = "selection_mode"
            case selectedToolIDs = "selected_tool_ids"
            case updatedAt = "updated_at"
        }
    }

    private struct State: Codable, Sendable, Equatable {
        let schemaVersion: Int
        var projects: [String: Record]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case projects
        }
    }

    private static let maximumProjects = 2_048
    private let url: URL
    private let clock: any Clock
    private let lock = NSLock()
    private var state: State

    init(paths: AppPaths, clock: any Clock) throws {
        url = paths.projectToolPermissions
        self.clock = clock
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try OwnerOnlyAtomicFile.read(from: url, maximumBytes: 2 * 1_024 * 1_024)
            let decoded = try JSONDecoder().decode(State.self, from: data)
            guard decoded.schemaVersion == ManagerToolPermissionSnapshot.schemaVersion,
                  decoded.projects.count <= Self.maximumProjects,
                  decoded.projects.allSatisfy({ projectID, record in
                      UUID(uuidString: projectID) != nil
                          && record.selectedToolIDs.count <= ToolDefinitionCatalog.maximumDefinitions
                          && record.selectedToolIDs.count == Set(record.selectedToolIDs).count
                          && record.selectedToolIDs.allSatisfy(Self.isValidToolID)
                  }) else {
                throw ToolPermissionStoreError.invalidPersistence
            }
            state = decoded
        } else {
            state = State(schemaVersion: ManagerToolPermissionSnapshot.schemaVersion, projects: [:])
        }
    }

    func snapshot(
        projectID: ProjectID,
        generation: ProjectGeneration,
        catalog: ToolDefinitionCatalog,
        unavailableReasons: [String: String]
    ) throws -> ManagerToolPermissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try snapshotUnlocked(
            projectID: projectID,
            generation: generation,
            catalog: catalog,
            unavailableReasons: unavailableReasons
        )
    }

    func update(
        _ request: ManagerToolPermissionUpdate,
        projectID: ProjectID,
        generation: ProjectGeneration,
        catalog: ToolDefinitionCatalog,
        unavailableReasons: [String: String]
    ) throws -> ManagerToolPermissionSnapshot {
        let selected = request.selectedToolIDs
        guard selected.count <= ToolDefinitionCatalog.maximumDefinitions,
              selected.count == Set(selected).count,
              selected.allSatisfy(Self.isValidToolID),
              request.projectID == projectID.description,
              request.projectGeneration == generation.rawValue,
              request.selectionMode == .explicit || selected.isEmpty else {
            throw ToolPermissionStoreError.invalidSelection
        }

        lock.lock(); defer { lock.unlock() }
        let current = state.projects[projectID.description]
        let known = Set(catalog.definitions.map(\.name))
            .subtracting(ToolDefinitionCatalog.controlPlaneOnlyToolNames)
        let retainedMissing = Set(current?.selectedToolIDs ?? [])
        guard request.selectionMode != .explicit
                || Set(selected).isSubset(of: known.union(retainedMissing)) else {
            throw ToolPermissionStoreError.invalidSelection
        }
        let actualRevision = current?.revision ?? 0
        guard request.expectedPreferenceRevision == actualRevision else {
            throw ToolPermissionStoreError.staleRevision(
                expected: request.expectedPreferenceRevision,
                actual: actualRevision
            )
        }
        guard state.projects[projectID.description] != nil
                || state.projects.count < Self.maximumProjects else {
            throw ToolPermissionStoreError.invalidPersistence
        }
        let (nextRevision, overflow) = actualRevision.addingReportingOverflow(1)
        guard !overflow else { throw ToolPermissionStoreError.invalidPersistence }
        let retainedSelection = request.selectionMode == .explicit ? selected.sorted() : []
        var nextState = state
        nextState.projects[projectID.description] = Record(
            revision: nextRevision,
            selectionMode: request.selectionMode,
            selectedToolIDs: retainedSelection,
            updatedAt: ISO8601.string(from: clock.now())
        )
        try persistUnlocked(nextState)
        state = nextState
        return try snapshotUnlocked(
            projectID: projectID,
            generation: generation,
            catalog: catalog,
            unavailableReasons: unavailableReasons
        )
    }

    private func snapshotUnlocked(
        projectID: ProjectID,
        generation: ProjectGeneration,
        catalog: ToolDefinitionCatalog,
        unavailableReasons: [String: String]
    ) throws -> ManagerToolPermissionSnapshot {
        let record = state.projects[projectID.description]
        let mode = record?.selectionMode ?? .recommended
        let definitions = catalog.definitions.filter {
            !ToolDefinitionCatalog.controlPlaneOnlyToolNames.contains($0.name)
        }
        let registered = Set(definitions.map(\.name))
        let available = registered.subtracting(unavailableReasons.keys)
        let recommended = Set(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools)
            .intersection(registered)
        let selected: Set<String>
        switch mode {
        case .recommended: selected = recommended
        case .allEligible: selected = available
        case .explicit: selected = Set(record?.selectedToolIDs ?? [])
        }
        let missingSelections = selected.subtracting(registered).sorted().map { toolID in
            ManagerToolCatalogEntry(
                id: toolID,
                displayName: Self.displayName(toolID),
                description: "This previously selected tool is not registered by the current build.",
                category: .other,
                categoryDisplayName: ManagerToolCategory.other.displayName,
                recommended: false,
                available: false,
                unavailableReason: "Not registered by the current Forge tool catalog.",
                highImpact: Self.isHighImpact(toolID)
            )
        }
        let entries = definitions.map { definition in
            let category = ManagerToolCategory.classify(definition.name)
            let unavailableReason = unavailableReasons[definition.name]
            return ManagerToolCatalogEntry(
                id: definition.name,
                displayName: Self.displayName(definition.name),
                description: definition.description,
                category: category,
                categoryDisplayName: category.displayName,
                recommended: recommended.contains(definition.name),
                available: unavailableReason == nil,
                unavailableReason: unavailableReason,
                highImpact: Self.isHighImpact(definition.name)
            )
        } + missingSelections
        let orderedEntries = entries.sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.id < $1.id
        }
        let catalogRevision = try Self.catalogRevision(entries: orderedEntries)
        return ManagerToolPermissionSnapshot(
            schemaVersion: ManagerToolPermissionSnapshot.schemaVersion,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            preferenceRevision: record?.revision ?? 0,
            catalogRevision: catalogRevision,
            selectionMode: mode,
            selectedToolIDs: selected.sorted(),
            effectiveToolIDs: ToolGrantSemantics.expanded(selected)
                .intersection(available)
                .sorted(),
            tools: orderedEntries,
            updatedAt: record?.updatedAt
        )
    }

    private func persistUnlocked(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try OwnerOnlyAtomicFile.write(try encoder.encode(state), to: url)
    }

    private static func isValidToolID(_ toolID: String) -> Bool {
        !toolID.isEmpty
            && toolID == toolID.trimmingCharacters(in: .whitespacesAndNewlines)
            && toolID.utf8.count <= CanonicalToolDefinition.maximumNameBytes
    }

    private static func catalogRevision(entries: [ManagerToolCatalogEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return JSONSupport.sha256Hex(try encoder.encode(entries))
    }

    private static func displayName(_ toolID: String) -> String {
        toolID.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func isHighImpact(_ toolID: String) -> Bool {
        ToolRouter.isMutatingTool(toolID)
    }
}

private enum ProductionToolDefinitionSource {
    static func description(for name: String) -> String? {
        ContinuityControlToolName(rawValue: name)?.description
            ?? ProjectMemoryToolPack.description(for: name)
            ?? ContinuityLifecycleToolPack.description(for: name)
            ?? RuntimeJobToolPack.description(for: name)
            ?? baseDescriptions[name]
    }

    static func schema(for name: String) -> [String: Any]? {
        ContinuityControlToolName(rawValue: name)?.inputSchema
            ?? ProjectMemoryToolPack.schema(for: name)
            ?? ContinuityLifecycleToolPack.schema(for: name)
            ?? RuntimeJobToolPack.schema(for: name)
            ?? baseSchema(for: name)
    }

    private static let baseDescriptions: [String: String] = [
        "forge_status": "Runtime status: home, agents, open sessions, tools.",
        "agent_list": "List specialist agent playbooks.",
        "agent_get": "Get a specialist agent playbook by id.",
        "agent_context": "Alias of agent_get — full playbook body.",
        "agent_recommend": "Recommend a specialist agent for a task description.",
        "agent_run_start": "Start a durable specialist session (supersedes prior open sessions).",
        "agent_run_status": "Status of an agent session; reminds host to complete open runs.",
        "agent_run_complete": "Close a session with a report matching output_schema.",
        "session_checkpoint": "Soft-save context + open agent sessions for continuity (continue working).",
        "session_handoff": "Finalize context/agent handoff for a new chat; returns resume_seed. Prefer before context is full.",
        "context_get": "Load latest (or id) handoff packet — call first in every new chat bootstrap.",
        "context_list": "List recent context handoff packets.",
        "instruction_catalog": "Page the complete project/run-bound inventory for an immutable imported instruction snapshot before beginning work.",
        "instruction_read": "Read a byte-bounded UTF-8 window from one converted project/run-bound instruction document with a durable continuation cursor.",
        "fs_read": "Read a UTF-8 text file. Optional 1-based line window: offset (start line) + length/limit (line count). Response includes total_lines, start_line, end_line, has_more, next_offset. Do not re-call with the same offset when content was returned.",
        "fs_write": "Write a UTF-8 text file.",
        "fs_edit": "Replace occurrences of old with new in a file.",
        "fs_list": "List directory entries.",
        "fs_glob": "Find files by name pattern under a path.",
        "fs_mkdir": "Create a directory.",
        "fs_delete": "Delete a file or directory.",
        "fs_delete_recovery": "Query, resume, or acknowledge a retained protected delete transaction without reusing the deleted path.",
        "fs_move": "Move/rename a path.",
        "shell_exec": "Run a bash command with timeout.",
        "git_status": "git status --porcelain.",
        "git_diff": "git diff (optional staged).",
        "git_log": "git log --oneline.",
        "git_add": "git add path or -A.",
        "git_commit": "git commit -m message.",
        "pdf_write": "Write a PDF from markdown-ish text (stdlib, no pandoc).",
        "pdf_from_file": "Convert a local markdown/text file to PDF.",
        "search_text": "Recursive text search (grep).",
        "memory_set": "Store a durable key/value note in Forge local memory (survives chat sessions).",
        "memory_get": "Read a durable memory note by key.",
        "memory_list": "List durable memory notes (optional prefix/tag; hides internal agent and continuity keys by default).",
        "memory_delete": "Delete a durable memory note by key.",
        "memory_search": "Search durable memory notes by substring in key/body/tags.",
    ]

    private static func baseSchema(for name: String) -> [String: Any]? {
        guard baseDescriptions[name] != nil else { return nil }
        let object: [String: Any] = ["type": "object"]
        switch name {
        case "instruction_catalog":
            return [
                "type": "object",
                "properties": [
                    "snapshot_sha256": ["type": "string"],
                    "cursor": ["type": "integer", "minimum": 0],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 128],
                ] as [String: Any],
                "required": ["snapshot_sha256"],
                "additionalProperties": false,
            ]
        case "instruction_read":
            return [
                "type": "object",
                "properties": [
                    "snapshot_sha256": ["type": "string"],
                    "document_id": ["type": "string"],
                    "byte_offset": ["type": "integer", "minimum": 0],
                    "maximum_bytes": [
                        "type": "integer", "minimum": 1,
                        "maximum": ProjectInstructionQueueStore.maximumDeliveryBytes,
                    ],
                ] as [String: Any],
                "required": ["snapshot_sha256", "document_id"],
                "additionalProperties": false,
            ]
        case "agent_run_start":
            return [
                "type": "object",
                "properties": [
                    "agent_id": ["type": "string"] as [String: Any],
                    "goal": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["agent_id", "goal"],
            ]
        case "agent_run_status", "agent_run_complete":
            return [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string"] as [String: Any],
                    "report": ["type": "object"] as [String: Any],
                ] as [String: Any],
                "required": ["session_id"],
            ]
        case "agent_get", "agent_context":
            return [
                "type": "object",
                "properties": ["agent_id": ["type": "string"] as [String: Any]] as [String: Any],
                "required": ["agent_id"],
            ]
        case "agent_recommend":
            return [
                "type": "object",
                "properties": ["task": ["type": "string"] as [String: Any]] as [String: Any],
                "required": ["task"],
            ]
        case "session_checkpoint", "session_handoff":
            return [
                "type": "object",
                "properties": [
                    "goal": ["type": "string"] as [String: Any],
                    "status": ["type": "string"] as [String: Any],
                    "project_slug": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                    "narrative": ["type": "string"] as [String: Any],
                    "summary": ["type": "string", "description": "Alias for narrative"] as [String: Any],
                    "next_actions": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "blockers": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "key_files": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "decisions": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "chat_label": ["type": "string"] as [String: Any],
                    "handoff_id": ["type": "string", "description": "Update an existing packet"] as [String: Any],
                    "resume_seed": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "context_get":
            return [
                "type": "object",
                "properties": [
                    "handoff_id": ["type": "string"] as [String: Any],
                    "id": ["type": "string"] as [String: Any],
                    "resume_ready": ["type": "boolean", "description": "Prefer latest resume-ready packet"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "context_list":
            return [
                "type": "object",
                "properties": ["limit": ["type": "integer"] as [String: Any]] as [String: Any],
                "required": [] as [String],
            ]
        case "fs_read":
            return [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: Any],
                    "offset": [
                        "type": "integer",
                        "description": "1-based start line for a partial read",
                    ] as [String: Any],
                    "length": [
                        "type": "integer",
                        "description": "Number of lines to return (alias: limit)",
                    ] as [String: Any],
                    "limit": [
                        "type": "integer",
                        "description": "Alias for length — number of lines to return",
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["path"],
            ]
        case "fs_list", "fs_delete", "fs_mkdir":
            return [
                "type": "object",
                "properties": ["path": ["type": "string"] as [String: Any]] as [String: Any],
                "required": name == "fs_list" ? [] as [String] : ["path"],
            ]
        case "fs_delete_recovery":
            return [
                "type": "object",
                "properties": [
                    "transaction_id": [
                        "type": "string",
                        "description": "Transaction UUID returned by fs_delete",
                    ] as [String: Any],
                    "action": [
                        "type": "string",
                        "enum": ["query", "resume", "acknowledge"],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["transaction_id", "action"],
            ]
        case "fs_write":
            return [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: Any],
                    "content": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        case "shell_exec":
            return [
                "type": "object",
                "properties": [
                    "command": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                    "timeout_sec": ["type": "number"] as [String: Any],
                ] as [String: Any],
                "required": ["command"],
            ]
        case "pdf_write":
            return [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: Any],
                    "content": ["type": "string"] as [String: Any],
                    "title": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        case "pdf_from_file":
            return [
                "type": "object",
                "properties": [
                    "source_path": ["type": "string"] as [String: Any],
                    "dest_path": ["type": "string"] as [String: Any],
                    "title": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["source_path"],
            ]
        case "search_text":
            return [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string"] as [String: Any],
                    "path": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["pattern"],
            ]
        case "memory_set":
            return [
                "type": "object",
                "properties": [
                    "key": ["type": "string"] as [String: Any],
                    "body": ["type": "string"] as [String: Any],
                    "content": ["type": "string", "description": "Alias of body"] as [String: Any],
                    "tags": [
                        "type": "array",
                        "items": ["type": "string"] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
                "required": ["key", "body"],
            ]
        case "memory_get", "memory_delete":
            return [
                "type": "object",
                "properties": ["key": ["type": "string"] as [String: Any]] as [String: Any],
                "required": ["key"],
            ]
        case "memory_list":
            return [
                "type": "object",
                "properties": [
                    "prefix": ["type": "string"] as [String: Any],
                    "tag": ["type": "string"] as [String: Any],
                    "include_system": ["type": "boolean"] as [String: Any],
                    "include_body": ["type": "boolean"] as [String: Any],
                    "limit": ["type": "integer"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "memory_search":
            return [
                "type": "object",
                "properties": [
                    "query": ["type": "string"] as [String: Any],
                    "include_system": ["type": "boolean"] as [String: Any],
                    "include_body": ["type": "boolean"] as [String: Any],
                    "limit": ["type": "integer"] as [String: Any],
                ] as [String: Any],
                "required": ["query"],
            ]
        default:
            return object.merging([
                "properties": [:] as [String: Any],
                "additionalProperties": true,
            ]) { _, new in new }
        }
    }
}

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
                inputSchema: schemaWithSharedInvocationControls(schema)
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
        try definitions(allowedToolNames: allowedToolNames).map {
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
        }
    }
}

private enum ProductionToolDefinitionSource {
    static func description(for name: String) -> String? {
        ProjectMemoryToolPack.description(for: name)
            ?? ContinuityLifecycleToolPack.description(for: name)
            ?? RuntimeJobToolPack.description(for: name)
            ?? baseDescriptions[name]
    }

    static func schema(for name: String) -> [String: Any]? {
        ProjectMemoryToolPack.schema(for: name)
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

// ProjectMemoryToolPack.swift
// What: Exposes additive project_memory.* MCP tools without changing legacy memory tools.
// How: Wire dictionaries are validated into typed service calls and stable protocol errors.
// Why: Existing hosts retain compatibility while autonomous sessions gain scoped memory.

import Foundation

public struct ProjectMemoryToolPack: ToolPackHandling {
    public static let names = [
        "project_memory.initialize", "project_memory.remember", "project_memory.remember_batch",
        "project_memory.search", "project_memory.get", "project_memory.update",
        "project_memory.forget", "project_memory.list_recent", "project_memory.link",
        "project_memory.export", "project_memory.import", "project_memory.status",
    ]

    public var toolNames: [String] { Self.names }

    public init() {}

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        let control = cancellation ?? ToolCallCancellation()
        do {
            if let deadline = try validateDeadline(arguments) {
                try control.tightenDeadline(milliseconds: deadline)
            }
            try control.checkCancellation()
            let payload: [String: Any]
            switch name {
            case "project_memory.initialize": payload = try initialize(arguments, service: app.projectMemory, control: control)
            case "project_memory.remember": payload = try remember(arguments, service: app.projectMemory, control: control)
            case "project_memory.remember_batch": payload = try rememberBatch(arguments, service: app.projectMemory, control: control)
            case "project_memory.search": payload = try search(arguments, service: app.projectMemory, control: control)
            case "project_memory.get": payload = try get(arguments, service: app.projectMemory, control: control)
            case "project_memory.update": payload = try update(arguments, service: app.projectMemory, control: control)
            case "project_memory.forget": payload = try forget(arguments, service: app.projectMemory, control: control)
            case "project_memory.list_recent": payload = try listRecent(arguments, service: app.projectMemory, control: control)
            case "project_memory.link": payload = try link(arguments, service: app.projectMemory, control: control)
            case "project_memory.export": payload = try app.projectMemory.export(projectID: try projectID(arguments), cancellation: control)
            case "project_memory.import": payload = try importArtifact(arguments, service: app.projectMemory, control: control)
            case "project_memory.status": payload = try app.projectMemory.status(projectID: try projectID(arguments), cancellation: control)
            default: throw ProjectMemoryError.invalidRequest("unknown project memory tool")
            }
            return .success(payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch let error as ProjectMemoryError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: error == .databaseBusy)
        } catch {
            return .failure(code: "invalid_request", message: error.localizedDescription, retryable: false)
        }
    }

    public static func description(for name: String) -> String? {
        let descriptions = [
            "project_memory.initialize": "Create or open a durable project-scoped memory store.",
            "project_memory.remember": "Store one redacted, deduplicated project memory record.",
            "project_memory.remember_batch": "Store a bounded batch transactionally.",
            "project_memory.search": "Search one project with deterministic bounded pagination.",
            "project_memory.get": "Fetch project memory records by stable ID.",
            "project_memory.update": "Update a record with optimistic version checking.",
            "project_memory.forget": "Tombstone a record in one project.",
            "project_memory.list_recent": "List recent project records with bounded pagination.",
            "project_memory.link": "Create an idempotent typed link between records.",
            "project_memory.export": "Create a checksummed project memory export artifact.",
            "project_memory.import": "Preview or transactionally import a checksummed export.",
            "project_memory.status": "Report project memory health, sizes, capabilities, and limits.",
        ]
        return descriptions[name]
    }

    public static func schema(for name: String) -> [String: Any]? {
        guard names.contains(name) else { return nil }
        let string: [String: Any] = ["type": "string"]
        let projectProperty: [String: Any] = ["project_id": string]
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        switch name {
        case "project_memory.initialize":
            return object([
                "project_path": string, "project_id": string, "display_name": string,
                "repository_identity": string, "idempotency_key": string,
                "deadline_ms": ["type": "integer"],
            ], required: ["project_path"])
        case "project_memory.remember":
            return object(projectProperty.merging(writeProperties()) { _, new in new }, required: ["project_id", "kind", "title", "summary"])
        case "project_memory.remember_batch":
            return object([
                "project_id": string,
                "items": ["type": "array", "maxItems": ProjectMemoryLimits.current.maximumBatchCount, "items": ["type": "object"]],
                "deadline_ms": ["type": "integer"],
            ], required: ["project_id", "items"])
        case "project_memory.search":
            return object(projectProperty.merging([
                "query": string, "kinds": ["type": "array", "items": string], "tags": ["type": "array", "items": string],
                "session_id": string, "limit": ["type": "integer"], "cursor": string,
                "include_body": ["type": "boolean"], "maximum_response_bytes": ["type": "integer"],
                "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id", "query"])
        case "project_memory.get":
            return object(projectProperty.merging([
                "id": string, "ids": ["type": "array", "items": string], "include_body": ["type": "boolean"],
                "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id"])
        case "project_memory.update":
            return object(projectProperty.merging([
                "id": string, "expected_version": ["type": "integer"], "title": string, "summary": string,
                "body": string, "tags": ["type": "array", "items": string], "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id", "id", "expected_version"])
        case "project_memory.forget":
            return object(projectProperty.merging(["id": string, "deadline_ms": ["type": "integer"]]) { _, new in new }, required: ["project_id", "id"])
        case "project_memory.list_recent":
            return object(projectProperty.merging([
                "kinds": ["type": "array", "items": string], "session_id": string, "limit": ["type": "integer"],
                "cursor": string, "include_body": ["type": "boolean"], "maximum_response_bytes": ["type": "integer"],
                "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id"])
        case "project_memory.link":
            return object(projectProperty.merging([
                "source_id": string, "target_id": string, "relation": string, "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id", "source_id", "target_id", "relation"])
        case "project_memory.import":
            return object(projectProperty.merging([
                "artifact": string, "preview": ["type": "boolean"], "merge_policy": string,
                "deadline_ms": ["type": "integer"],
            ]) { _, new in new }, required: ["project_id", "artifact"])
        default:
            return object(projectProperty.merging(["deadline_ms": ["type": "integer"]]) { _, new in new }, required: ["project_id"])
        }
    }

    private static func writeProperties() -> [String: Any] {
        let string: [String: Any] = ["type": "string"]
        return [
            "kind": string, "title": string, "summary": string, "body": string,
            "tags": ["type": "array", "items": string], "importance": ["type": "number"],
            "confidence": ["type": "number"], "source_kind": string, "source_reference": string,
            "session_id": string, "expires_at": string, "related_ids": ["type": "array", "items": string],
            "idempotency_key": string, "deadline_ms": ["type": "integer"],
        ]
    }

    private func initialize(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let path = string(arguments, "project_path") ?? string(arguments, "path") else {
            throw ProjectMemoryError.invalidRequest("project_path is required")
        }
        return try service.initialize(
            path: path, projectID: string(arguments, "project_id"), displayName: string(arguments, "display_name"),
            repositoryIdentity: string(arguments, "repository_identity"), cancellation: control
        )
    }

    private func remember(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        try service.remember(projectID: projectID(arguments), write: write(arguments), cancellation: control)
    }

    private func rememberBatch(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let items = arguments["items"] as? [[String: Any]] else {
            throw ProjectMemoryError.invalidRequest("items must be an array of objects")
        }
        return try service.rememberBatch(
            projectID: projectID(arguments),
            writes: items.map(write),
            cancellation: control
        )
    }

    private func search(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let query = string(arguments, "query") else { throw ProjectMemoryError.invalidRequest("query is required") }
        return try service.search(
            projectID: projectID(arguments), query: query, kinds: strings(arguments["kinds"]), tags: strings(arguments["tags"]),
            sessionID: string(arguments, "session_id"), limit: integer(arguments, "limit") ?? service.limits.defaultPageCount,
            cursor: string(arguments, "cursor"), includeBody: boolean(arguments, "include_body") ?? false,
            maximumResponseBytes: integer(arguments, "maximum_response_bytes") ?? service.limits.defaultResponseBytes,
            cancellation: control
        )
    }

    private func get(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        var ids = strings(arguments["ids"])
        if let id = string(arguments, "id") { ids.insert(id, at: 0) }
        return try service.get(
            projectID: projectID(arguments), ids: Array(Set(ids)).sorted(),
            includeBody: boolean(arguments, "include_body") ?? false, cancellation: control
        )
    }

    private func update(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let id = string(arguments, "id"), let expected = integer(arguments, "expected_version") else {
            throw ProjectMemoryError.invalidRequest("id and expected_version are required")
        }
        return try service.update(
            projectID: projectID(arguments), id: id, expectedVersion: expected,
            title: string(arguments, "title"), summary: string(arguments, "summary"), body: string(arguments, "body"),
            tags: arguments["tags"] == nil ? nil : strings(arguments["tags"]), cancellation: control
        )
    }

    private func forget(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let id = string(arguments, "id") else { throw ProjectMemoryError.invalidRequest("id is required") }
        return try service.forget(projectID: projectID(arguments), id: id, cancellation: control)
    }

    private func listRecent(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        try service.listRecent(
            projectID: projectID(arguments), kinds: strings(arguments["kinds"]), sessionID: string(arguments, "session_id"),
            limit: integer(arguments, "limit") ?? service.limits.defaultPageCount, cursor: string(arguments, "cursor"),
            includeBody: boolean(arguments, "include_body") ?? false,
            maximumResponseBytes: integer(arguments, "maximum_response_bytes") ?? service.limits.defaultResponseBytes,
            cancellation: control
        )
    }

    private func link(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let source = string(arguments, "source_id"), let target = string(arguments, "target_id"),
              let relation = string(arguments, "relation") else {
            throw ProjectMemoryError.invalidRequest("source_id, target_id, and relation are required")
        }
        return try service.link(
            projectID: projectID(arguments), sourceID: source, targetID: target,
            relation: relation, cancellation: control
        )
    }

    private func importArtifact(
        _ arguments: [String: Any],
        service: ProjectMemoryService,
        control: ToolCallCancellation
    ) throws -> [String: Any] {
        guard let artifact = string(arguments, "artifact") else { throw ProjectMemoryError.invalidRequest("artifact is required") }
        return try service.importRecords(
            projectID: projectID(arguments), artifactPath: artifact,
            preview: boolean(arguments, "preview") ?? true, mergePolicy: string(arguments, "merge_policy"),
            cancellation: control
        )
    }

    private func write(_ arguments: [String: Any]) throws -> ProjectMemoryWrite {
        guard let kind = string(arguments, "kind"), let title = string(arguments, "title"),
              let summary = string(arguments, "summary") else {
            throw ProjectMemoryError.invalidRequest("kind, title, and summary are required")
        }
        return ProjectMemoryWrite(
            kind: kind, title: title, summary: summary, body: string(arguments, "body"),
            tags: strings(arguments["tags"]), importance: number(arguments, "importance") ?? 0.5,
            confidence: number(arguments, "confidence") ?? 1,
            sourceKind: string(arguments, "source_kind") ?? "external_integration",
            sourceReference: string(arguments, "source_reference"), sessionID: string(arguments, "session_id"),
            expiresAt: string(arguments, "expires_at"), relatedIDs: strings(arguments["related_ids"]),
            idempotencyKey: string(arguments, "idempotency_key")
        )
    }

    private func projectID(_ arguments: [String: Any]) throws -> String {
        guard let id = string(arguments, "project_id"), UUID(uuidString: id) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        return id.lowercased()
    }

    private func validateDeadline(_ arguments: [String: Any]) throws -> Int? {
        guard let deadline = integer(arguments, "deadline_ms") else { return nil }
        guard (1...60_000).contains(deadline) else {
            throw ProjectMemoryError.invalidRequest("deadline_ms must be within 1...60000")
        }
        return deadline
    }

    private func string(_ arguments: [String: Any], _ key: String) -> String? {
        ToolArgHelpers.string(arguments, key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func integer(_ arguments: [String: Any], _ key: String) -> Int? { ToolArgHelpers.int(arguments, key) }
    private func boolean(_ arguments: [String: Any], _ key: String) -> Bool? { ToolArgHelpers.bool(arguments, key) }
    private func number(_ arguments: [String: Any], _ key: String) -> Double? {
        if let value = arguments[key] as? Double { return value }
        if let value = arguments[key] as? Int { return Double(value) }
        if let value = arguments[key] as? NSNumber { return value.doubleValue }
        return nil
    }

    private func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        if let value = value as? String { return [value] }
        return []
    }
}

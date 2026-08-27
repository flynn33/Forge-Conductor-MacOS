// MemoryToolPack.swift
// What: Exposes durable SQLite-backed memory notes as MCP tools for cross-session continuity.
// How: Validates keys/bodies/tags, delegates persistence to SQLiteStore, and returns stable
// JSON payloads for set/get/list/delete/search without requiring an agent session.
// Why: LM Studio chat history is ephemeral; models need a durable local memory surface.

import Foundation

/// Durable key/value memory tools backed by `memory_notes` in the Forge home SQLite store.
public struct MemoryToolPack: ToolPackHandling {
    public init() {}

    public var toolNames: [String] {
        ["memory_set", "memory_get", "memory_list", "memory_delete", "memory_search"]
    }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        try cancellation?.checkCancellation()
        switch name {
        case "memory_set":
            return try memorySet(arguments: arguments, app: app, cancellation: cancellation)
        case "memory_get":
            return try memoryGet(arguments: arguments, app: app, cancellation: cancellation)
        case "memory_list":
            return try memoryList(arguments: arguments, app: app, cancellation: cancellation)
        case "memory_delete":
            return try memoryDelete(arguments: arguments, app: app, cancellation: cancellation)
        case "memory_search":
            return try memorySearch(arguments: arguments, app: app, cancellation: cancellation)
        default:
            return nil
        }
    }

    // MARK: - Handlers

    private func memorySet(
        arguments: [String: Any],
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let key = validatedKey(arguments) else {
            return .failure(code: "invalid_key", message: Self.keyHelp, retryable: true)
        }
        guard let body = ToolArgHelpers.string(arguments, "body")
            ?? ToolArgHelpers.string(arguments, "content")
            ?? ToolArgHelpers.string(arguments, "value") else {
            return .failure(code: "missing_body", message: "body (or content/value) is required", retryable: true)
        }
        if body.utf8.count > SQLiteStore.memoryBodyMaxBytes {
            return .failure(
                code: "body_too_large",
                message: "body exceeds \(SQLiteStore.memoryBodyMaxBytes) bytes",
                retryable: true
            )
        }
        let tags = parseTags(arguments["tags"])
        try cancellation?.checkCancellation()
        let note = try app.store.memorySetAndGetNote(
            key: key,
            body: body,
            tags: tags,
            cancellation: cancellation
        )
        return .success([
            "ok": true,
            "stored": true,
            "note": note.asDictionary(includeBody: true),
            "home": app.paths.home.path,
        ])
    }

    private func memoryGet(
        arguments: [String: Any],
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let key = validatedKey(arguments) else {
            return .failure(code: "invalid_key", message: Self.keyHelp, retryable: true)
        }
        guard let note = try app.store.memoryGetNote(
            key: key,
            cancellation: cancellation
        ) else {
            return .success([
                "ok": true,
                "found": false,
                "key": key,
                "note": NSNull(),
            ])
        }
        return .success([
            "ok": true,
            "found": true,
            "key": key,
            "body": note.body,
            "tags": note.tags,
            "created_at": note.createdAt,
            "updated_at": note.updatedAt,
            "note": note.asDictionary(includeBody: true),
        ])
    }

    private func memoryList(
        arguments: [String: Any],
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let prefix = ToolArgHelpers.string(arguments, "prefix")
        let tag = ToolArgHelpers.string(arguments, "tag")
        let includeSystem = ToolArgHelpers.bool(arguments, "include_system") ?? false
        let includeBody = ToolArgHelpers.bool(arguments, "include_body") ?? false
        let limit = ToolArgHelpers.int(arguments, "limit") ?? SQLiteStore.memoryQueryDefaultLimit

        let notes = try app.store.memoryList(
            prefix: prefix,
            tag: tag,
            includeSystem: includeSystem,
            limit: limit,
            cancellation: cancellation
        )
        let total = try app.store.memoryCount(
            includeSystem: includeSystem,
            cancellation: cancellation
        )
        return .success([
            "ok": true,
            "count": notes.count,
            "total": total,
            "prefix": prefix as Any,
            "tag": tag as Any,
            "include_system": includeSystem,
            "notes": notes.map { $0.asDictionary(includeBody: includeBody) },
        ])
    }

    private func memoryDelete(
        arguments: [String: Any],
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let key = validatedKey(arguments) else {
            return .failure(code: "invalid_key", message: Self.keyHelp, retryable: true)
        }
        let existed = try app.store.memoryGetNote(
            key: key,
            cancellation: cancellation
        ) != nil
        try cancellation?.checkCancellation()
        let deleted = try app.store.memoryDelete(key: key, cancellation: cancellation)
        return .success([
            "ok": true,
            "key": key,
            "deleted": deleted,
            "existed": existed,
            "system_key": MemoryNote.isSystemKey(key),
        ])
    }

    private func memorySearch(
        arguments: [String: Any],
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let query = ToolArgHelpers.string(arguments, "query")
            ?? ToolArgHelpers.string(arguments, "q")
            ?? ToolArgHelpers.string(arguments, "pattern") else {
            return .failure(code: "missing_query", message: "query is required", retryable: true)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(code: "empty_query", message: "query must not be empty", retryable: true)
        }
        let includeSystem = ToolArgHelpers.bool(arguments, "include_system") ?? false
        let includeBody = ToolArgHelpers.bool(arguments, "include_body") ?? true
        let limit = ToolArgHelpers.int(arguments, "limit") ?? SQLiteStore.memoryQueryDefaultLimit

        let notes = try app.store.memorySearch(
            query: trimmed,
            includeSystem: includeSystem,
            limit: limit,
            cancellation: cancellation
        )
        return .success([
            "ok": true,
            "query": trimmed,
            "count": notes.count,
            "include_system": includeSystem,
            "notes": notes.map { $0.asDictionary(includeBody: includeBody) },
        ])
    }

    // MARK: - Validation

    private static let keyHelp =
        "key is required: non-empty, max \(SQLiteStore.memoryKeyMaxBytes) bytes, no control characters"

    private func validatedKey(_ arguments: [String: Any]) -> String? {
        guard let raw = ToolArgHelpers.string(arguments, "key") else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        guard key.utf8.count <= SQLiteStore.memoryKeyMaxBytes else { return nil }
        // Reject ASCII control characters (including NUL) that break logs/tools.
        if key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        return key
    }

    private func parseTags(_ raw: Any?) -> [String] {
        if let arr = raw as? [String] {
            return Array(Set(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        }
        if let arr = raw as? [Any] {
            let strings = arr.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(strings)).sorted()
        }
        if let s = raw as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Comma-separated tags: "project,jamf"
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return Array(Set(parts)).sorted()
        }
        return []
    }
}

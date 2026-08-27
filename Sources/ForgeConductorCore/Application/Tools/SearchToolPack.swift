// SearchToolPack.swift
// What: Provides recursive text search inside authorized workspaces.
// How: It validates the query/root, invokes the native process adapter with limits,
// and converts matches into a stable tool response.
// Why: Search behavior stays modular and cannot silently broaden filesystem access.

import Foundation

/// Search tools: search_text (recursive grep).
public struct SearchToolPack: ToolPackHandling {
    private let runner = ProcessRunner()

    public init() {}

    public var toolNames: [String] { ["search_text"] }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard name == "search_text" else { return nil }
        try cancellation?.checkCancellation()
        guard let pattern = ToolArgHelpers.string(arguments, "pattern") else {
            return .failure(code: "missing_pattern", message: "pattern required")
        }
        let path = ToolArgHelpers.string(arguments, "path") ?? FileManager.default.currentDirectoryPath
        let result = try runner.run(
            executable: "/usr/bin/grep",
            arguments: [
                "-RIn",
                "--exclude-dir=node_modules",
                "--exclude-dir=.git",
                pattern,
                ToolArgHelpers.resolvePath(path).path,
            ],
            timeoutSec: 20,
            cancellation: cancellation
        )
        let lines = result.stdout.split(separator: "\n").prefix(200).map(String.init)
        let ok = result.exitCode == 0 || result.exitCode == 1
        return ToolResult(
            ok: ok,
            payload: [
            "ok": ok,
            "pattern": pattern,
            "matches": Array(lines),
            "count": lines.count,
            "exit_code": result.exitCode,
            "timed_out": result.timedOut,
            "stderr": result.stderr,
        ],
            isError: !ok
        )
    }
}

// SearchToolPack.swift
// What: Provides recursive text search through the host process's native filesystem access.
// How: It validates the query/root, invokes the native process adapter with limits,
// and converts matches into a stable tool response.
// Why: Search behavior stays modular while inheriting the host's macOS privacy grants.

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
                "--", pattern,
                RuntimePathCanonicalizer.canonicalURL(ToolArgHelpers.resolvePath(path)).path,
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
            "executable": "/usr/bin/grep",
            "search_options": "-RIn;exclude=node_modules,.git",
            "pattern": pattern,
            "matches": Array(lines),
            "count": lines.count,
            "matches_truncated": result.stdoutTruncated
                || result.stdout.split(separator: "\n").count > lines.count,
            "stdout_truncated": result.stdoutTruncated,
            "exit_code": result.exitCode,
            "timed_out": result.timedOut,
            "stderr": result.stderr,
            "stderr_truncated": result.stderrTruncated,
        ],
            isError: !ok
        )
    }
}

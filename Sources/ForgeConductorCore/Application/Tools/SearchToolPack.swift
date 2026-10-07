// SearchToolPack.swift
// What: Provides recursive text search through the host process's native filesystem access.
// How: It validates the query/root, invokes the native process adapter with limits,
// and converts matches into a stable tool response.
// Why: Search behavior stays modular while inheriting the host's macOS privacy grants.

import Foundation
import CoreFoundation

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
        let contextLines = arguments["context_lines"] == nil ? 0 : Self.contextLines(arguments["context_lines"])
        guard let contextLines,
              let includes = Self.globs(arguments, key: "include"),
              let excludes = Self.globs(arguments, key: "exclude") else {
            return .failure(code: "invalid_search_options",
                message: "context_lines must be 0...20; include/exclude must contain at most 32 nonempty filename globs (256 bytes each)")
        }
        let path = ToolArgHelpers.string(arguments, "path") ?? FileManager.default.currentDirectoryPath
        var options = ["-RIn", "--exclude-dir=node_modules", "--exclude-dir=.git"]
        if contextLines > 0 { options.append("-C\(contextLines)") }
        options.append(contentsOf: includes.map { "--include=\($0)" })
        for glob in excludes {
            options.append("--exclude=\(glob)")
            options.append("--exclude-dir=\(glob)")
        }
        let result = try runner.run(
            executable: "/usr/bin/grep",
            arguments: options + [
                "--", pattern,
                RuntimePathCanonicalizer.canonicalURL(ToolArgHelpers.resolvePath(path)).path,
            ],
            timeoutSec: 20,
            cancellation: cancellation
        )
        let lines = result.stdout.split(separator: "\n").prefix(200).map(String.init)
        let ok = !result.timedOut && (result.exitCode == 0 || result.exitCode == 1)
        return ToolResult(
            ok: ok,
            payload: [
            "ok": ok,
            "executable": "/usr/bin/grep",
            "search_options": "-RIn;exclude=node_modules,.git",
            "pattern": pattern,
            "context_lines": contextLines,
            "include": includes,
            "exclude": excludes,
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

    private static func globs(_ arguments: [String: Any], key: String) -> [String]? {
        guard let raw = arguments[key] else { return [] }
        guard let values = raw as? [String], values.count <= 32,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else { return nil }
        return values
    }

    private static func contextLines(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), (0...20).contains(value) else { return nil }
        return value
    }
}

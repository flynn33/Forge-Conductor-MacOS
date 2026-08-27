// ShellToolPack.swift
// What: Implements the explicitly granted shell-execution capability.
// How: It requires an active authorized workspace, applies timeout/output limits,
// and delegates process mechanics to ProcessRunner before returning structured status.
// Why: The most powerful tool needs a narrow, independently reviewable boundary.

import Foundation

/// Shell tool pack: shell_exec.
public struct ShellToolPack: ToolPackHandling {
    public static let maximumTimeoutSec: TimeInterval = 120
    private let runner = ProcessRunner()

    public init() {}

    public var toolNames: [String] { ["shell_exec"] }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard name == "shell_exec" else { return nil }
        try cancellation?.checkCancellation()
        guard let command = ToolArgHelpers.string(arguments, "command"), !command.isEmpty else {
            return .failure(code: "missing_command", message: "command required")
        }
        let cwd = ToolArgHelpers.string(arguments, "cwd")
        let requestedTimeout = (arguments["timeout_sec"] as? NSNumber)?.doubleValue
            ?? Double(app.config.int("shell", "default_timeout_sec", default: 30))
        guard requestedTimeout.isFinite, requestedTimeout > 0 else {
            return .failure(
                code: "invalid_timeout",
                message: "timeout_sec must be finite and positive",
                retryable: false
            )
        }
        let timeout = min(requestedTimeout, Self.maximumTimeoutSec)
        let result = try runner.run(
            executable: "/bin/bash",
            arguments: ["-lc", command],
            currentDirectory: cwd,
            timeoutSec: timeout,
            maximumOutputBytes: 100_000,
            cancellation: cancellation
        )
        let ok = result.exitCode == 0 && !result.timedOut
        return ToolResult(
            ok: ok,
            payload: [
                "ok": ok,
                "exit_code": result.exitCode,
                "stdout": String(result.stdout.prefix(80_000)),
                "stderr": String(result.stderr.prefix(20_000)),
                "timed_out": result.timedOut,
                "stdout_truncated": result.stdoutTruncated,
                "stderr_truncated": result.stderrTruncated,
                "command": command,
                "cwd": cwd as Any,
            ],
            isError: !ok
        )
    }
}

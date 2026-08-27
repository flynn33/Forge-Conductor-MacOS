// GitToolPack.swift
// What: Adapts a focused set of Git commands into structured tool operations.
// How: It validates command arguments, invokes ProcessRunner with bounded capture,
// and returns normalized results without embedding shell composition.
// Why: Version-control integration remains replaceable and separately auditable.

import Foundation

private final class GitMutationLockTable: @unchecked Sendable {
    private let locks = (0..<64).map { _ in NSLock() }

    func withLock<Value>(
        key: String,
        cancellation: ToolCallCancellation?,
        _ body: () throws -> Value
    ) throws -> Value {
        let lock = locks[stableIndex(for: key)]
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
        }
        do {
            try cancellation?.checkCancellation()
        } catch {
            lock.unlock()
            throw error
        }
        defer { lock.unlock() }
        return try body()
    }

    private func stableIndex(for key: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(locks.count))
    }
}

/// Git tool pack: status, diff, log, add, commit.
public struct GitToolPack: ToolPackHandling {
    private static let mutationLocks = GitMutationLockTable()
    private static let maximumReflogEntries = 32
    private static let maximumProofBytes = 1_048_576

    private struct CommitInvocationIdentity {
        let priorHead: String?
        let reflogAction: String
    }

    private struct AddInvocationIdentity {
        let indexPath: String
        let pathspec: String?
        let priorProof: String
        let expectedProof: String
    }

    private let runner: ProcessRunner
    private let commandTimeoutSeconds: TimeInterval

    public init() {
        runner = ProcessRunner()
        commandTimeoutSeconds = 30
    }

    init(runner: ProcessRunner, commandTimeoutSeconds: TimeInterval) {
        self.runner = runner
        self.commandTimeoutSeconds = max(0, commandTimeoutSeconds)
    }

    public var toolNames: [String] {
        ["git_status", "git_diff", "git_log", "git_add", "git_commit"]
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
        let cwd = ToolArgHelpers.string(arguments, "cwd") ?? FileManager.default.currentDirectoryPath
        var gitArgs: [String] = []
        switch name {
        case "git_status":
            gitArgs = ["status", "--porcelain=v1", "-b"]
        case "git_diff":
            gitArgs = ["diff"]
            if ToolArgHelpers.bool(arguments, "staged") == true { gitArgs.append("--cached") }
        case "git_log":
            let n = ToolArgHelpers.int(arguments, "limit") ?? 20
            gitArgs = ["log", "-n", "\(n)", "--oneline"]
        case "git_add":
            if let path = ToolArgHelpers.string(arguments, "path") { gitArgs = ["add", "--", path] }
            else { gitArgs = ["add", "-A"] }
        case "git_commit":
            let msg = ToolArgHelpers.string(arguments, "message") ?? "chore: forge-conductor commit"
            gitArgs = ["commit", "-m", msg]
        default:
            return .failure(code: "unknown_git", message: name)
        }
        if name == "git_add" || name == "git_commit" {
            let lockKey = try repositoryMutationKey(cwd: cwd, cancellation: cancellation)
            return try Self.mutationLocks.withLock(key: lockKey, cancellation: cancellation) {
                try execute(
                    name: name,
                    gitArgs: gitArgs,
                    cwd: cwd,
                    cancellation: cancellation
                )
            }
        }
        return try execute(
            name: name,
            gitArgs: gitArgs,
            cwd: cwd,
            cancellation: cancellation
        )
    }

    private func execute(
        name: String,
        gitArgs: [String],
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let commitIdentity = name == "git_commit"
            ? try commitInvocationIdentity(cwd: cwd, cancellation: cancellation)
            : nil
        let addIdentity = name == "git_add"
            ? try addInvocationIdentity(
                cwd: cwd,
                pathspec: gitArgs.count == 3 ? gitArgs[2] : nil,
                cancellation: cancellation
            )
            : nil
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: "git",
                arguments: gitArgs,
                currentDirectory: cwd,
                environment: commitIdentity.map {
                    ["GIT_REFLOG_ACTION": $0.reflogAction]
                },
                timeoutSec: commandTimeoutSeconds,
                cancellation: cancellation
            )
        } catch is CancellationError {
            if let commitIdentity,
               let reconciled = reconciledCommittedResult(
                    cwd: cwd,
                    identity: commitIdentity
               ) {
                return reconciled
            }
            if let addIdentity,
               let reconciled = reconciledAddedResult(
                cwd: cwd,
                identity: addIdentity
               ) {
                return reconciled
            }
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            if let commitIdentity,
               let reconciled = reconciledCommittedResult(
                    cwd: cwd,
                    identity: commitIdentity
               ) {
                return reconciled
            }
            if let addIdentity,
               let reconciled = reconciledAddedResult(
                cwd: cwd,
                identity: addIdentity
               ) {
                return reconciled
            }
            throw error
        }
        if result.exitCode != 0 || result.timedOut {
            if let commitIdentity,
               let reconciled = reconciledCommittedResult(cwd: cwd, identity: commitIdentity) {
                return reconciled
            }
            if let addIdentity,
               let reconciled = reconciledAddedResult(cwd: cwd, identity: addIdentity) {
                return reconciled
            }
        }
        let ok = result.exitCode == 0 && !result.timedOut
        return ToolResult(
            ok: ok,
            payload: [
                "ok": ok,
                "exit_code": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "cwd": cwd,
                "timed_out": result.timedOut,
            ],
            isError: !ok
        )
    }

    private func commitInvocationIdentity(
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> CommitInvocationIdentity {
        try cancellation?.checkCancellation()
        let priorHead = try currentHead(cwd: cwd, cancellation: cancellation)
        // Preserve the prior preflight contract: an unmerged or unreadable index
        // fails before commit is launched. The resulting tree is intentionally not
        // part of reconciliation because pre-commit hooks may update the index.
        _ = try stagedTree(cwd: cwd, cancellation: cancellation)
        return CommitInvocationIdentity(
            priorHead: priorHead,
            reflogAction: "commit forge-conductor-\(UUID().uuidString.lowercased())"
        )
    }

    private func addInvocationIdentity(
        cwd: String,
        pathspec: String?,
        cancellation: ToolCallCancellation?
    ) throws -> AddInvocationIdentity? {
        try cancellation?.checkCancellation()
        let pathResult = try runner.run(
            executable: "git",
            arguments: ["rev-parse", "--git-path", "index"],
            currentDirectory: cwd,
            timeoutSec: 5,
            cancellation: cancellation
        )
        guard pathResult.exitCode == 0, !pathResult.timedOut,
              !pathResult.stdoutTruncated else { return nil }
        let rawPath = pathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        let indexPath = rawPath.hasPrefix("/")
            ? rawPath
            : URL(fileURLWithPath: cwd).appendingPathComponent(rawPath).standardizedFileURL.path
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-git-index-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let expectedIndex = temporaryDirectory.appendingPathComponent("index").path
        if FileManager.default.fileExists(atPath: indexPath) {
            let copy = try runner.run(
                executable: "/bin/cp",
                arguments: ["-p", indexPath, expectedIndex],
                currentDirectory: cwd,
                timeoutSec: 5,
                cancellation: cancellation
            )
            guard copy.exitCode == 0, !copy.timedOut else { return nil }
        }

        var expectedArguments = ["-c", "core.hooksPath=/dev/null", "add"]
        if let pathspec {
            expectedArguments.append(contentsOf: ["--", pathspec])
        } else {
            expectedArguments.append("-A")
        }
        let expectedAdd = try runner.run(
            executable: "git",
            arguments: expectedArguments,
            currentDirectory: cwd,
            environment: ["GIT_INDEX_FILE": expectedIndex],
            timeoutSec: 10,
            cancellation: cancellation
        )
        guard expectedAdd.exitCode == 0, !expectedAdd.timedOut else { return nil }

        guard let priorProof = try indexProof(
            indexPath: indexPath,
            pathspec: pathspec,
            cwd: cwd,
            cancellation: cancellation
        ), let expectedProof = try indexProof(
            indexPath: expectedIndex,
            pathspec: pathspec,
            cwd: cwd,
            cancellation: cancellation
        ) else { return nil }
        return AddInvocationIdentity(
            indexPath: indexPath,
            pathspec: pathspec,
            priorProof: priorProof,
            expectedProof: expectedProof
        )
    }

    private func repositoryMutationKey(
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> String {
        let result = try runner.run(
            executable: "git",
            arguments: ["rev-parse", "--git-common-dir"],
            currentDirectory: cwd,
            timeoutSec: 5,
            cancellation: cancellation
        )
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated else {
            return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: cwd).appendingPathComponent(raw)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func currentHead(
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        let result = try runner.run(
            executable: "git",
            arguments: ["rev-parse", "--verify", "HEAD"],
            currentDirectory: cwd,
            timeoutSec: 5,
            cancellation: cancellation
        )
        return result.exitCode == 0
            ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    private func stagedTree(
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> String {
        let result = try runner.run(
            executable: "git",
            arguments: ["write-tree"],
            currentDirectory: cwd,
            timeoutSec: 5,
            cancellation: cancellation
        )
        guard result.exitCode == 0, !result.stdoutTruncated else {
            throw NSError(
                domain: "GitToolPack",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func indexFingerprint(
        at path: String,
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        let result = try runner.run(
            executable: "git",
            arguments: ["hash-object", "--no-filters", "--", path],
            currentDirectory: cwd,
            timeoutSec: 5,
            cancellation: cancellation
        )
        guard result.exitCode == 0, !result.stdoutTruncated else { return nil }
        let fingerprint = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint.isEmpty ? nil : fingerprint
    }

    private func indexProof(
        indexPath: String,
        pathspec: String?,
        cwd: String,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        if let pathspec {
            let result = try runner.run(
                executable: "git",
                arguments: ["ls-files", "--stage", "-z", "--", pathspec],
                currentDirectory: cwd,
                environment: ["GIT_INDEX_FILE": indexPath],
                timeoutSec: 5,
                maximumOutputBytes: Self.maximumProofBytes,
                cancellation: cancellation
            )
            guard result.exitCode == 0, !result.timedOut,
                  !result.stdoutTruncated else { return nil }
            return result.stdout
        }
        // A full add has no narrower pathspec. The index file hash is a compact,
        // exact proof of the complete expected index transaction.
        return try indexFingerprint(
            at: indexPath,
            cwd: cwd,
            cancellation: cancellation
        ) ?? "<missing-index>"
    }

    /// A commit may update HEAD before a post-commit hook finishes. If transport
    /// cancellation then terminates Git, the unique reflog action proves which Git
    /// invocation advanced HEAD. The bounded search still finds that exact commit if
    /// another actor advances HEAD before reconciliation finishes.
    private func reconciledCommittedResult(
        cwd: String,
        identity: CommitInvocationIdentity
    ) -> ToolResult? {
        guard let reflog = try? runner.run(
            executable: "git",
            arguments: [
                "reflog", "show",
                "--max-count=\(Self.maximumReflogEntries)",
                "--format=%H%x00%gs",
                "HEAD",
            ],
            currentDirectory: cwd,
            timeoutSec: 5,
            maximumOutputBytes: Self.maximumProofBytes
        ), reflog.exitCode == 0, !reflog.timedOut,
           !reflog.stdoutTruncated else {
            return nil
        }
        let matchingEntry = reflog.stdout.split(separator: "\n").lazy.compactMap { line -> String? in
            let fields = String(line).components(separatedBy: "\0")
            guard fields.count == 2,
                  fields[1].hasPrefix("\(identity.reflogAction):") else { return nil }
            return fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
        guard let committedHead = matchingEntry,
              let inspection = try? runner.run(
                executable: "git",
                arguments: ["show", "-s", "--format=%H%n%P", committedHead],
                currentDirectory: cwd,
                timeoutSec: 5,
                maximumOutputBytes: 16_384
              ), inspection.exitCode == 0, !inspection.timedOut,
              !inspection.stdoutTruncated else { return nil }
        let inspectionLines = inspection.stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard inspectionLines.count >= 2,
              inspectionLines[0].trimmingCharacters(in: .whitespacesAndNewlines) == committedHead else {
            return nil
        }
        let parents = inspectionLines[1].split(separator: " ").map(String.init)
        let parentsMatch: Bool
        if let priorHead = identity.priorHead {
            // Normal and merge commits both retain the prior HEAD as first parent.
            parentsMatch = parents.first == priorHead
        } else {
            parentsMatch = parents.isEmpty
        }
        guard committedHead != identity.priorHead, parentsMatch else { return nil }
        return ToolResult(
            ok: true,
            payload: [
                "ok": true,
                "exit_code": Int32(0),
                "stdout": "Committed \(committedHead)\n",
                "stderr": "",
                "cwd": cwd,
                "commit": committedHead,
                "reconciled": true,
            ],
            isError: false
        )
    }

    /// Git writes its index before the process necessarily exits (for example,
    /// before a post-index-change hook returns). Reconciliation compares the requested
    /// pathspec with a precomputed alternate-index result, preventing an unrelated
    /// index write from being mistaken for this invocation.
    private func reconciledAddedResult(
        cwd: String,
        identity: AddInvocationIdentity
    ) -> ToolResult? {
        guard identity.expectedProof != identity.priorProof,
              let currentProof = try? indexProof(
                indexPath: identity.indexPath,
                pathspec: identity.pathspec,
                cwd: cwd,
                cancellation: nil
              ),
              currentProof == identity.expectedProof else {
            return nil
        }
        var payload: [String: Any] = [
            "ok": true,
            "exit_code": Int32(0),
            "stdout": "Staged requested changes\n",
            "stderr": "",
            "cwd": cwd,
            "reconciled": true,
        ]
        if let fingerprint = try? indexFingerprint(
            at: identity.indexPath,
            cwd: cwd,
            cancellation: nil
        ) {
            payload["index_fingerprint"] = fingerprint
        }
        if let pathspec = identity.pathspec { payload["pathspec"] = pathspec }
        return ToolResult(ok: true, payload: payload, isError: false)
    }
}

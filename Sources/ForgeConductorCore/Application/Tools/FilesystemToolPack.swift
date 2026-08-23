// FilesystemToolPack.swift
// What: Implements the bounded file-management tool module.
// How: It performs read, write, edit, list, glob, move, directory, and delete
// operations only after ToolAuthorizationService has approved canonical paths.
// Why: Filesystem connector code is isolated from routing and domain services.

import Foundation

/// Filesystem tool pack: read/write/edit/list/glob/mkdir/delete/move.
public struct FilesystemToolPack: ToolPackHandling {
    private static let maximumTextFileBytes = 2 * 1024 * 1024
    public static let maximumListEntries = 1_000
    public init() {}

    public var toolNames: [String] {
        ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_move"]
    }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        switch name {
        case "fs_read": return try fsRead(arguments)
        case "fs_write": return try fsWrite(arguments)
        case "fs_edit": return try fsEdit(arguments)
        case "fs_list": return try fsList(arguments)
        case "fs_glob": return try fsGlob(arguments, runner: ProcessRunner())
        case "fs_mkdir": return try fsMkdir(arguments)
        case "fs_delete": return try fsDelete(arguments)
        case "fs_move": return try fsMove(arguments)
        default: return nil
        }
    }

    private func fsRead(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumTextFileBytes else {
            return .failure(
                code: "file_too_large",
                message: "Text reads are limited to \(Self.maximumTextFileBytes) bytes"
            )
        }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(code: "not_found", message: "Not a readable file: \(url.path)")
        }

        // Line-based windowing. Models often request offset/length (or limit) for
        // large files. Ignoring those args returns the whole file every time and
        // can trap the host model in an identical fs_read loop.
        let lines: [String] = text.isEmpty
            ? []
            : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let totalLines = lines.count
        let requestedOffset = ToolArgHelpers.int(args, "offset")
            ?? ToolArgHelpers.int(args, "start_line")
        let requestedLength = ToolArgHelpers.int(args, "length")
            ?? ToolArgHelpers.int(args, "limit")
            ?? ToolArgHelpers.int(args, "max_lines")

        let startLine: Int
        let endLine: Int
        if let requestedOffset {
            // 1-based inclusive start. offset past EOF → empty window, not a full re-read.
            startLine = max(1, requestedOffset)
            let count = max(0, requestedLength ?? Self.defaultWindowLines)
            if startLine > totalLines || count == 0 {
                endLine = startLine - 1
            } else {
                let remainingLines = totalLines - startLine + 1
                let windowCount = min(count, remainingLines)
                endLine = startLine + windowCount - 1
            }
        } else if let requestedLength {
            startLine = 1
            let count = max(0, requestedLength)
            endLine = count == 0 ? 0 : min(totalLines, count)
        } else {
            startLine = 1
            endLine = totalLines
        }

        let content: String
        if startLine > totalLines || endLine < startLine {
            content = ""
        } else {
            content = lines[(startLine - 1)..<endLine].joined(separator: "\n")
        }

        let hasMore = endLine < totalLines
        var payload: [String: Any] = [
            "path": url.path,
            "content": content,
            "size": data.count,
            "total_lines": totalLines,
            "start_line": startLine,
            "end_line": max(endLine, startLine - 1),
            "line_count": max(0, endLine - startLine + 1),
            "has_more": hasMore,
        ]
        if hasMore {
            payload["next_offset"] = endLine + 1
            payload["note"] =
                "Partial read (lines \(startLine)–\(endLine) of \(totalLines)). " +
                "Continue with offset=\(endLine + 1) (1-based) and a new length. " +
                "Do not repeat the same offset/length."
        } else if totalLines == 0 {
            payload["note"] = "File is empty."
        } else if startLine > totalLines {
            payload["note"] =
                "offset \(startLine) is past end of file (\(totalLines) lines). " +
                "Stop paginating this path."
        } else if startLine == 1 {
            payload["note"] =
                "Complete file contents (\(totalLines) lines). " +
                "Do not re-read this path unless the file changes."
        } else {
            payload["note"] =
                "Reached end of file at line \(totalLines). Stop paginating this path."
        }
        return .success(payload)
    }

    /// Default line window when offset is provided without length/limit.
    private static let defaultWindowLines = 200

    private func fsWrite(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let content = ToolArgHelpers.string(args, "content") else {
            return .failure(code: "missing_args", message: "path and content required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return .success(["path": url.path, "bytes_written": data.count])
    }

    private func fsEdit(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let old = ToolArgHelpers.string(args, "old"),
              let new = ToolArgHelpers.string(args, "new") else {
            return .failure(code: "missing_args", message: "path, old, new required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumTextFileBytes else {
            return .failure(
                code: "file_too_large",
                message: "Text edits are limited to \(Self.maximumTextFileBytes) bytes"
            )
        }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(code: "not_found", message: url.path)
        }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            return .failure(code: "no_match", message: "old string not found")
        }
        text = text.replacingOccurrences(of: old, with: new)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .success(["path": url.path, "replacements": count])
    }

    private func fsList(_ args: [String: Any]) throws -> ToolResult {
        let path = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let url = ToolArgHelpers.resolvePath(path)
        let allItems = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        let items = Array(allItems.prefix(Self.maximumListEntries))
        return .success([
            "path": url.path,
            "entries": items,
            "truncated": allItems.count > items.count,
            "maximum_entries": Self.maximumListEntries,
        ])
    }

    private func fsGlob(_ args: [String: Any], runner: ProcessRunner) throws -> ToolResult {
        let pattern = ToolArgHelpers.string(args, "pattern") ?? "*"
        let root = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let rootURL = ToolArgHelpers.resolvePath(root)
        let result = try runner.run(
            executable: "/usr/bin/find",
            arguments: [rootURL.path, "-name", pattern],
            timeoutSec: 15
        )
        let files = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .success(["path": rootURL.path, "pattern": pattern, "matches": Array(files.prefix(500))])
    }

    private func fsMkdir(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .success(["path": url.path, "ok": true])
    }

    private func fsDelete(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.removeItem(at: url)
        return .success(["path": url.path, "deleted": true])
    }

    private func fsMove(_ args: [String: Any]) throws -> ToolResult {
        guard let src = ToolArgHelpers.string(args, "path")
                ?? ToolArgHelpers.string(args, "src")
                ?? ToolArgHelpers.string(args, "source"),
              let dest = ToolArgHelpers.string(args, "dest")
                ?? ToolArgHelpers.string(args, "destination") else {
            return .failure(code: "missing_args", message: "path/src and dest required")
        }
        let s = ToolArgHelpers.resolvePath(src)
        let d = ToolArgHelpers.resolvePath(dest)
        try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: s, to: d)
        return .success(["src": s.path, "dest": d.path])
    }
}

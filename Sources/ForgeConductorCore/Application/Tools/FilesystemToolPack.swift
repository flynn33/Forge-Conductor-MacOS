// FilesystemToolPack.swift
// What: Implements the bounded file-management tool module.
// How: It performs read, write, edit, list, glob, move, directory, and delete
// operations only after ToolAuthorizationService has approved canonical paths.
// Why: Filesystem connector code is isolated from routing and domain services.

import Foundation
import Darwin
import CryptoKit

/// Filesystem tool pack: read/write/edit/list/glob/mkdir/delete/move.
public struct FilesystemToolPack: ToolPackHandling {
    private static let maximumTextFileBytes = 2 * 1024 * 1024
    private static let maximumRecursiveMutationEntries = 100_000
    private static let maximumMutationSeconds: TimeInterval = 300
    public static let maximumListEntries = 1_000
    private let deletionStepObserver: (@Sendable (Int) -> Void)?
    private let deletionMutationObserver: (@Sendable (DeletionMutationStep) -> Void)?
    private let moveStepObserver: (@Sendable (MoveStep) -> Void)?
    private let forceCrossVolumeMove: Bool
    private let directorySynchronizer: @Sendable (URL) throws -> Void

    enum MoveStep: Sendable, Equatable {
        case preparedDestinationDirectories
        case beforeSameVolumeRename
        case beforeDestinationInstall
        case copiedToStaging
        case installedDestination
        case beforeSourceFenceVerification
        case beforeSourceEntryRemoval(String)
        case synchronizingStagingEntry(Int)
        case reconcilingHardLinkGroup
        case removedStagingEntry(Int)
        case removedSourceEntry(Int)
    }

    enum DeletionMutationStep: Sendable, Equatable {
        case beforeRemoving(String)
    }

    public init() {
        deletionStepObserver = nil
        deletionMutationObserver = nil
        moveStepObserver = nil
        forceCrossVolumeMove = false
        directorySynchronizer = { try Self.synchronizeDirectory($0) }
    }

    init(deletionStepObserver: (@Sendable (Int) -> Void)?) {
        self.deletionStepObserver = deletionStepObserver
        deletionMutationObserver = nil
        moveStepObserver = nil
        forceCrossVolumeMove = false
        directorySynchronizer = { try Self.synchronizeDirectory($0) }
    }

    init(
        deletionStepObserver: (@Sendable (Int) -> Void)?,
        moveStepObserver: (@Sendable (MoveStep) -> Void)?,
        forceCrossVolumeMove: Bool
    ) {
        self.deletionStepObserver = deletionStepObserver
        deletionMutationObserver = nil
        self.moveStepObserver = moveStepObserver
        self.forceCrossVolumeMove = forceCrossVolumeMove
        directorySynchronizer = { try Self.synchronizeDirectory($0) }
    }

    init(
        deletionStepObserver: (@Sendable (Int) -> Void)?,
        moveStepObserver: (@Sendable (MoveStep) -> Void)?,
        forceCrossVolumeMove: Bool,
        directorySynchronizer: @escaping @Sendable (URL) throws -> Void
    ) {
        self.deletionStepObserver = deletionStepObserver
        deletionMutationObserver = nil
        self.moveStepObserver = moveStepObserver
        self.forceCrossVolumeMove = forceCrossVolumeMove
        self.directorySynchronizer = directorySynchronizer
    }

    init(deletionMutationObserver: (@Sendable (DeletionMutationStep) -> Void)?) {
        deletionStepObserver = nil
        self.deletionMutationObserver = deletionMutationObserver
        moveStepObserver = nil
        forceCrossVolumeMove = false
        directorySynchronizer = { try Self.synchronizeDirectory($0) }
    }

    public var toolNames: [String] {
        ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_move"]
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
        case "fs_read": return try fsRead(arguments, cancellation: cancellation)
        case "fs_write": return try fsWrite(arguments, cancellation: cancellation)
        case "fs_edit": return try fsEdit(arguments, cancellation: cancellation)
        case "fs_list": return try fsList(arguments, cancellation: cancellation)
        case "fs_glob": return try fsGlob(arguments, runner: ProcessRunner(), cancellation: cancellation)
        case "fs_mkdir": return try fsMkdir(arguments, cancellation: cancellation)
        case "fs_delete": return try fsDelete(arguments, cancellation: cancellation)
        case "fs_move": return try fsMove(arguments, cancellation: cancellation)
        default: return nil
        }
    }

    private func fsRead(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let data: Data
        let text: String
        do {
            (data, text) = try Self.readBoundedUTF8Text(
                at: url,
                cancellation: cancellation
            )
        } catch BoundedTextReadError.tooLarge {
            return .failure(
                code: "file_too_large",
                message: "Text reads are limited to \(Self.maximumTextFileBytes) bytes"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            return .failure(code: "not_found", message: "Not a readable file: \(url.path)")
        }
        try cancellation?.checkCancellation()

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
        try cancellation?.checkCancellation()
        return .success(payload)
    }

    /// Default line window when offset is provided without length/limit.
    private static let defaultWindowLines = 200

    private func fsWrite(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let content = ToolArgHelpers.string(args, "content") else {
            return .failure(code: "missing_args", message: "path and content required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let data = Data(content.utf8)
        guard data.count <= Self.maximumTextFileBytes else {
            return .failure(
                code: "content_too_large",
                message: "Text writes are limited to \(Self.maximumTextFileBytes) bytes",
                retryable: false
            )
        }
        try cancellation?.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return .success(["path": url.path, "bytes_written": data.count])
    }

    private func fsEdit(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let old = ToolArgHelpers.string(args, "old"),
              let new = ToolArgHelpers.string(args, "new") else {
            return .failure(code: "missing_args", message: "path, old, new required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        var text: String
        do {
            (_, text) = try Self.readBoundedUTF8Text(
                at: url,
                cancellation: cancellation
            )
        } catch BoundedTextReadError.tooLarge {
            return .failure(
                code: "file_too_large",
                message: "Text edits are limited to \(Self.maximumTextFileBytes) bytes"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            return .failure(code: "not_found", message: url.path)
        }
        try cancellation?.checkCancellation()
        var count = 0
        var searchStart = text.startIndex
        while !old.isEmpty,
              let range = text.range(of: old, range: searchStart..<text.endIndex) {
            try cancellation?.checkCancellation()
            count += 1
            searchStart = range.upperBound
        }
        guard count > 0 else {
            return .failure(code: "no_match", message: "old string not found")
        }
        let removed = old.utf8.count.multipliedReportingOverflow(by: count)
        let added = new.utf8.count.multipliedReportingOverflow(by: count)
        let retained = text.utf8.count.subtractingReportingOverflow(removed.partialValue)
        let projected = retained.partialValue.addingReportingOverflow(added.partialValue)
        guard !removed.overflow, !added.overflow, !retained.overflow, !projected.overflow,
              projected.partialValue <= Self.maximumTextFileBytes else {
            return .failure(
                code: "content_too_large",
                message: "Edited text would exceed \(Self.maximumTextFileBytes) bytes",
                retryable: false
            )
        }
        text = text.replacingOccurrences(of: old, with: new)
        try cancellation?.checkCancellation()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .success(["path": url.path, "replacements": count])
    }

    private func fsList(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let path = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let url = ToolArgHelpers.resolvePath(path)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var items: [String] = []
        items.reserveCapacity(Self.maximumListEntries)
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            try cancellation?.checkCancellation()
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
            if items.count == Self.maximumListEntries {
                truncated = true
                break
            }
            items.append(child.lastPathComponent)
        }
        if let enumerationError { throw enumerationError }
        items.sort()
        try cancellation?.checkCancellation()
        return .success([
            "path": url.path,
            "entries": items,
            "truncated": truncated,
            "maximum_entries": Self.maximumListEntries,
        ])
    }

    private func fsGlob(
        _ args: [String: Any],
        runner: ProcessRunner,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        let pattern = ToolArgHelpers.string(args, "pattern") ?? "*"
        let root = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let rootURL = ToolArgHelpers.resolvePath(root)
        let result = try runner.run(
            executable: "/usr/bin/find",
            arguments: [rootURL.path, "-name", pattern],
            timeoutSec: 15,
            cancellation: cancellation
        )
        let files = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .success(["path": rootURL.path, "pattern": pattern, "matches": Array(files.prefix(500))])
    }

    private func fsMkdir(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try cancellation?.checkCancellation()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .success(["path": url.path, "ok": true])
    }

    private func fsDelete(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try cancellation?.checkCancellation()
        let plan: [DeletionEntry]
        do {
            plan = try Self.recursiveDeletionPlan(at: url, cancellation: cancellation)
        } catch FilesystemMutationError.entryLimitExceeded {
            return .failure(
                code: "filesystem_mutation_limit",
                message: "Recursive deletion exceeds the \(Self.maximumRecursiveMutationEntries)-entry limit",
                retryable: false
            )
        }
        guard let rootEntry = plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        let expectedIdentities = Dictionary(
            uniqueKeysWithValues: plan.map { ($0.relativePath, $0.identity) }
        )
        let pinnedRoot = try Self.pinnedTreeRoot(
            at: url,
            expectedIdentity: rootEntry.identity
        )

        var removedCount = 0
        for entry in plan {
            do {
                try cancellation?.checkCancellation()
            } catch {
                guard removedCount > 0 else { throw error }
                return Self.partialMutationResult(
                    operation: "delete",
                    source: url,
                    destination: nil,
                    completedEntries: removedCount,
                    error: error
                )
            }
            do {
                try Self.removeEntry(
                    entry,
                    root: pinnedRoot,
                    expectedIdentities: expectedIdentities,
                    beforeRemoval: {
                        deletionMutationObserver?(.beforeRemoving(entry.relativePath))
                    }
                )
            } catch {
                guard removedCount > 0 else { throw error }
                return Self.partialMutationResult(
                    operation: "delete",
                    source: url,
                    destination: nil,
                    completedEntries: removedCount,
                    error: error
                )
            }
            removedCount += 1
            deletionStepObserver?(removedCount)
        }
        if Self.pathEntryExists(url) {
            return Self.partialMutationResult(
                operation: "delete",
                source: url,
                destination: nil,
                completedEntries: removedCount,
                error: SourceFenceError.changed
            )
        }
        return .success([
            "path": url.path,
            "deleted": true,
            "deleted_entries": removedCount,
        ])
    }

    private func fsMove(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let src = ToolArgHelpers.string(args, "path")
                ?? ToolArgHelpers.string(args, "src")
                ?? ToolArgHelpers.string(args, "source"),
              let dest = ToolArgHelpers.string(args, "dest")
                ?? ToolArgHelpers.string(args, "destination") else {
            return .failure(code: "missing_args", message: "path/src and dest required")
        }
        let s = ToolArgHelpers.resolvePath(src)
        let d = ToolArgHelpers.resolvePath(dest)
        try cancellation?.checkCancellation()
        guard let sourceInformation = try Self.lstatInformationIfExists(at: s) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSFilePathErrorKey: s.path]
            )
        }
        let sourceIdentity = PathIdentity(sourceInformation)
        let createdDestinationDirectories: [URL]
        do {
            createdDestinationDirectories = try createDurableDirectoryHierarchy(
                at: d.deletingLastPathComponent(),
                cancellation: cancellation
            )
        } catch let failure as DirectoryHierarchyFailure {
            guard !failure.createdDirectories.isEmpty else { throw failure.underlying }
            var result = Self.partialMutationResult(
                operation: "move",
                source: s,
                destination: d,
                completedEntries: failure.createdDirectories.count,
                error: failure.underlying
            )
            result.payload["created_directories"] = failure.createdDirectories.map(\.path)
            return result
        }
        moveStepObserver?(.preparedDestinationDirectories)
        do {
            try cancellation?.checkCancellation()
        } catch {
            guard !createdDestinationDirectories.isEmpty else { throw error }
            return Self.partialMoveResult(
                source: s,
                destination: d,
                completedEntries: createdDestinationDirectories.count,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }
        var requiresCrossVolumeMove = forceCrossVolumeMove
        var sameVolumeRenameReceipt: PinnedRenameReceipt?
        if !requiresCrossVolumeMove {
            do {
                sameVolumeRenameReceipt = try Self.renameExclusively(
                    source: s,
                    destination: d,
                    expectedSourceIdentity: sourceIdentity,
                    beforeRename: {
                        try cancellation?.checkCancellation()
                        moveStepObserver?(.beforeSameVolumeRename)
                        try cancellation?.checkCancellation()
                    }
                )
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EXDEV) {
                    requiresCrossVolumeMove = true
                } else {
                    guard !createdDestinationDirectories.isEmpty else {
                        if error is SourceFenceError {
                            return .failure(
                                code: "source_changed",
                                message: error.localizedDescription,
                                retryable: false
                            )
                        }
                        throw error
                    }
                    return Self.partialMoveResult(
                        source: s,
                        destination: d,
                        completedEntries: createdDestinationDirectories.count,
                        error: error,
                        createdDirectories: createdDestinationDirectories
                    )
                }
            }
        }
        if !requiresCrossVolumeMove {
            guard let sameVolumeRenameReceipt else {
                throw SourceFenceError.changed
            }
            if !sameVolumeRenameReceipt.requestedNamespaceStable {
                let durabilityConfirmed = (try? Self.synchronizePinnedRenameParents(
                    sameVolumeRenameReceipt
                )) != nil
                return Self.namespaceChangedAfterRenameResult(
                    source: s,
                    destination: d,
                    completedEntries: max(1, createdDestinationDirectories.count),
                    durabilityConfirmed: durabilityConfirmed,
                    createdDirectories: createdDestinationDirectories
                )
            }
            // Rename is the irreversible boundary. A late cancellation must not
            // conceal the completed move.
            do {
                try Self.synchronizePinnedRenameParents(sameVolumeRenameReceipt)
                try synchronizeMoveParents(source: s, destination: d)
                return Self.committedMoveResult(
                    source: s,
                    destination: d,
                    durabilityConfirmed: true,
                    durabilityError: nil
                )
            } catch {
                return Self.committedMoveResult(
                    source: s,
                    destination: d,
                    durabilityConfirmed: false,
                    durabilityError: error
                )
            }
        }

        return try crossVolumeMove(
            source: s,
            destination: d,
            expectedSourceIdentity: sourceIdentity,
            createdDestinationDirectories: createdDestinationDirectories,
            cancellation: cancellation
        )
    }

    private func crossVolumeMove(
        source: URL,
        destination: URL,
        expectedSourceIdentity: PathIdentity,
        createdDestinationDirectories: [URL],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        if try Self.itemType(at: destination).exists {
            let error = NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EEXIST),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
            guard !createdDestinationDirectories.isEmpty else { throw error }
            return Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: createdDestinationDirectories.count,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }
        let availableSeconds = min(
            Self.maximumMutationSeconds,
            cancellation?.remainingTimeInterval ?? Self.maximumMutationSeconds
        )
        let operationDeadline = ProcessInfo.processInfo.systemUptime + max(0, availableSeconds)
        let sourceFence: SourceFence
        do {
            sourceFence = try Self.captureSourceFence(
                at: source,
                cancellation: cancellation,
                deadline: operationDeadline
            )
            guard sourceFence.entriesByRelativePath["."]?.pathIdentity == expectedSourceIdentity else {
                throw SourceFenceError.changed
            }
        } catch {
            return try prepublicationMoveFailureResult(
                source: source,
                destination: destination,
                error: error,
                createdDestinationDirectories: createdDestinationDirectories
            )
        }
        // The copy is private until it has been fully synchronized. Publishing it
        // with an exclusive rename preserves the no-overwrite contract even when a
        // competing writer creates the destination after authorization.
        let stagingRoot = destination.deletingLastPathComponent().appendingPathComponent(
            ".forge-move-\(UUID().uuidString.lowercased())"
        )
        let staging = stagingRoot.appendingPathComponent("payload")
        var pinnedStagingTree: PinnedDeletionTree?
        var stagingPayloadInstalled = false
        defer {
            let stagingExisted = pinnedStagingTree.map(Self.conservativelyPinnedDeletionTreeExists)
                ?? ((try? Self.itemType(at: stagingRoot).exists) == true)
            if stagingExisted {
                do {
                    if let pinnedStagingTree {
                        if stagingPayloadInstalled {
                            try Self.discardPublishedStagingRoot(
                                pinnedStagingTree,
                                cancellation: cancellation,
                                deadline: operationDeadline,
                                stepObserver: moveStepObserver
                            )
                        } else {
                            try Self.discardPinnedDeletionTree(
                                pinnedStagingTree,
                                cancellation: cancellation,
                                deadline: operationDeadline,
                                stepObserver: moveStepObserver
                            )
                        }
                    } else {
                        try Self.discardPrivateStaging(
                            at: stagingRoot,
                            cancellation: cancellation,
                            deadline: operationDeadline,
                            stepObserver: moveStepObserver
                        )
                    }
                    try Self.checkMutationBoundary(
                        cancellation: cancellation,
                        deadline: operationDeadline
                    )
                    try directorySynchronizer(destination.deletingLastPathComponent())
                } catch {
                    // The primary result path reports any surviving staging state.
                    // This defer is only a final best-effort fallback.
                }
            }
        }
        do {
            _ = try createDurableDirectoryHierarchy(at: stagingRoot, cancellation: cancellation)
        } catch let failure as DirectoryHierarchyFailure {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: failure.underlying,
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        } catch {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: error,
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        }

        let remaining = min(
            cancellation?.remainingTimeInterval ?? Self.maximumMutationSeconds,
            max(0, operationDeadline - ProcessInfo.processInfo.systemUptime)
        )
        let timeout = max(0.001, min(Self.maximumMutationSeconds, remaining))
        do {
            let result = try ProcessRunner().run(
                executable: "/bin/cp",
                arguments: ["-pR", source.path, staging.path],
                timeoutSec: timeout,
                cancellation: cancellation
            )
            if result.timedOut {
                return try stagingFailureResult(
                    source: source,
                    destination: destination,
                    stagingRoot: stagingRoot,
                    error: ToolCallDeadlineExceeded(),
                    createdDestinationDirectories: createdDestinationDirectories,
                    cancellation: cancellation,
                    deadline: operationDeadline
                )
            }
            guard result.exitCode == 0 else {
                let copyError = NSError(
                    domain: "FilesystemToolPack",
                    code: Int(result.exitCode),
                    userInfo: [
                        NSLocalizedDescriptionKey: result.stderr.isEmpty
                            ? "Cross-volume copy failed"
                            : result.stderr,
                    ]
                )
                return try stagingFailureResult(
                    source: source,
                    destination: destination,
                    stagingRoot: stagingRoot,
                    error: copyError,
                    createdDestinationDirectories: createdDestinationDirectories,
                    cancellation: cancellation,
                    deadline: operationDeadline
                )
            }
        } catch is CancellationError {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: CancellationError(),
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        } catch let error as ToolCallDeadlineExceeded {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: error,
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        }

        let stagedRootIdentity: PathIdentity
        do {
            try Self.synchronizeTree(
                at: staging,
                cancellation: cancellation,
                deadline: operationDeadline,
                stepObserver: moveStepObserver
            )
            try Self.checkMutationBoundary(
                cancellation: cancellation,
                deadline: operationDeadline
            )
            try directorySynchronizer(stagingRoot)
            try Self.checkMutationBoundary(
                cancellation: cancellation,
                deadline: operationDeadline
            )
            moveStepObserver?(.copiedToStaging)
            try Self.verifiedSourceFence(
                at: source,
                expected: sourceFence,
                cancellation: cancellation,
                deadline: operationDeadline
            )
            let stagedFence = try Self.captureSourceFence(
                at: staging,
                cancellation: cancellation,
                deadline: operationDeadline
            )
            guard stagedFence.copiedContent == sourceFence.copiedContent else {
                throw SourceFenceError.changed
            }
            guard let stagedRoot = stagedFence.entriesByRelativePath["."] else {
                throw SourceFenceError.changed
            }
            stagedRootIdentity = stagedRoot.pathIdentity
            pinnedStagingTree = try Self.pinnedDeletionTree(
                at: stagingRoot,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        } catch {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: error,
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        }

        let installReceipt: PinnedRenameReceipt
        do {
            installReceipt = try Self.renameExclusively(
                source: staging,
                destination: destination,
                expectedSourceIdentity: stagedRootIdentity,
                beforeRename: {
                    try Self.checkMutationBoundary(
                        cancellation: cancellation,
                        deadline: operationDeadline
                    )
                    moveStepObserver?(.beforeDestinationInstall)
                    try Self.checkMutationBoundary(
                        cancellation: cancellation,
                        deadline: operationDeadline
                    )
                }
            )
        } catch {
            return try stagingFailureResult(
                source: source,
                destination: destination,
                stagingRoot: stagingRoot,
                error: error,
                createdDestinationDirectories: createdDestinationDirectories,
                cancellation: cancellation,
                deadline: operationDeadline,
                pinnedStagingTree: pinnedStagingTree
            )
        }
        stagingPayloadInstalled = true
        if !installReceipt.requestedNamespaceStable {
            _ = try? Self.synchronizePinnedRenameParents(installReceipt)
            if let pinnedStagingTree {
                try? Self.discardPublishedStagingRoot(
                    pinnedStagingTree,
                    cancellation: nil,
                    deadline: operationDeadline,
                    stepObserver: moveStepObserver
                )
            }
            return Self.namespaceChangedAfterRenameResult(
                source: source,
                destination: destination,
                completedEntries: 1,
                durabilityConfirmed: false,
                createdDirectories: createdDestinationDirectories
            )
        }
        do {
            try Self.synchronizePinnedRenameParents(installReceipt)
        } catch {
            return Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: 1,
                error: error,
                destinationComplete: true,
                createdDirectories: createdDestinationDirectories
            )
        }
        do {
            guard let pinnedStagingTree else { throw SourceFenceError.changed }
            try Self.discardPublishedStagingRoot(
                pinnedStagingTree,
                cancellation: cancellation,
                deadline: operationDeadline,
                stepObserver: moveStepObserver
            )
        } catch {
            var result = Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                destinationComplete: true,
                createdDirectories: createdDestinationDirectories
            )
            result.payload["staging_path"] = stagingRoot.path
            let stagingExists = pinnedStagingTree.map(Self.conservativelyPinnedDeletionTreeExists)
                ?? Self.pathEntryExists(stagingRoot)
            result.payload["staging_cleanup_required"] = stagingExists
            result.payload["staging_exists"] = stagingExists
            return result
        }
        moveStepObserver?(.installedDestination)
        do {
            try directorySynchronizer(destination.deletingLastPathComponent())
        } catch {
            return Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                destinationComplete: true,
                createdDirectories: createdDestinationDirectories
            )
        }

        moveStepObserver?(.beforeSourceFenceVerification)
        do {
            try Self.verifiedSourceFence(
                at: source,
                expected: sourceFence,
                cancellation: cancellation,
                deadline: operationDeadline
            )
            let publishedFence = try Self.captureSourceFence(
                at: destination,
                cancellation: cancellation,
                deadline: operationDeadline
            )
            guard publishedFence.copiedContent == sourceFence.copiedContent else {
                throw SourceFenceError.changed
            }
        } catch {
            return Self.sourceFencePartialResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }

        let plan: [DeletionEntry]
        do {
            plan = try Self.recursiveDeletionPlan(
                at: source,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        } catch {
            return Self.sourceFencePartialResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }

        do {
            try Self.verifiedSourceFence(
                at: source,
                expected: sourceFence,
                cancellation: cancellation,
                deadline: operationDeadline
            )
        } catch {
            return Self.sourceFencePartialResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }

        var expectedEntries = sourceFence.entriesByRelativePath
        let sourceIdentities = expectedEntries.mapValues(\.pathIdentity)
        guard let expectedRoot = expectedEntries["."] else {
            return Self.sourceFencePartialResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: SourceFenceError.changed,
                createdDirectories: createdDestinationDirectories
            )
        }
        let pinnedSourceRoot: PinnedTreeRoot
        do {
            pinnedSourceRoot = try Self.pinnedTreeRoot(
                at: source,
                expectedIdentity: expectedRoot.pathIdentity
            )
        } catch {
            return Self.sourceFencePartialResult(
                source: source,
                destination: destination,
                completedEntries: 0,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }
        var hardLinkGroups = sourceFence.hardLinkGroups
        var removedCount = 0
        for entry in plan {
            do {
                let relativePath = try Self.removeVerifiedDeletionCandidate(
                    entry,
                    pinnedRoot: pinnedSourceRoot,
                    expectedByRelativePath: expectedEntries,
                    expectedIdentities: sourceIdentities,
                    hardLinkGroups: hardLinkGroups,
                    cancellation: cancellation,
                    deadline: operationDeadline,
                    beforeRemoval: {
                        moveStepObserver?(.beforeSourceEntryRemoval(entry.relativePath))
                    }
                )
                removedCount += 1
                try Self.reconcileExpectedLinkStateAfterRemoval(
                    removedRelativePath: relativePath,
                    sourceRoot: source,
                    pinnedRoot: pinnedSourceRoot,
                    expectedIdentities: sourceIdentities,
                    expectedByRelativePath: &expectedEntries,
                    hardLinkGroups: &hardLinkGroups,
                    stepObserver: moveStepObserver,
                    cancellation: cancellation,
                    deadline: operationDeadline
                )
                moveStepObserver?(.removedSourceEntry(removedCount))
            } catch {
                return Self.sourceFencePartialResult(
                    source: source,
                    destination: destination,
                    completedEntries: removedCount,
                    error: error,
                    createdDirectories: createdDestinationDirectories
                )
            }
        }
        do {
            try directorySynchronizer(source.deletingLastPathComponent())
        } catch {
            return Self.committedMoveResult(
                source: source,
                destination: destination,
                durabilityConfirmed: false,
                durabilityError: error,
                movedEntries: removedCount
            )
        }
        return Self.committedMoveResult(
            source: source,
            destination: destination,
            durabilityConfirmed: true,
            durabilityError: nil,
            movedEntries: removedCount
        )
    }

    private struct PathIdentity: Equatable {
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32

        init(device: Int64, inode: UInt64, mode: UInt32, owner: UInt32, group: UInt32) {
            self.device = device
            self.inode = inode
            self.mode = mode
            self.owner = owner
            self.group = group
        }

        init(_ information: stat) {
            device = Int64(information.st_dev)
            inode = UInt64(information.st_ino)
            mode = UInt32(information.st_mode)
            owner = UInt32(information.st_uid)
            group = UInt32(information.st_gid)
        }

        var isDirectory: Bool {
            mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
        }

        func matches(_ information: stat) -> Bool {
            device == Int64(information.st_dev)
                && inode == UInt64(information.st_ino)
                && mode == UInt32(information.st_mode)
                && owner == UInt32(information.st_uid)
                && group == UInt32(information.st_gid)
        }
    }

    private struct DeletionEntry {
        let url: URL
        let relativePath: String
        let identity: PathIdentity

        var isDirectory: Bool { identity.isDirectory }
    }

    private enum FilesystemMutationError: Error {
        case entryLimitExceeded
    }

    private struct DirectoryHierarchyFailure: Error {
        let createdDirectories: [URL]
        let underlying: Error
    }

    private enum SourceFenceKind: String, Equatable {
        case regular
        case directory
        case symbolicLink
    }

    private struct SourceFenceEntry: Equatable {
        let relativePath: String
        let kind: SourceFenceKind
        let device: Int64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
        let linkCount: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let contentSHA256: String?

        var copiedContent: SourceFenceContentEntry {
            SourceFenceContentEntry(
                relativePath: relativePath,
                kind: kind,
                permissions: mode & 0o7777,
                size: kind == .directory ? 0 : size,
                contentSHA256: contentSHA256
            )
        }

        var pathIdentity: PathIdentity {
            PathIdentity(
                device: device,
                inode: inode,
                mode: mode,
                owner: owner,
                group: group
            )
        }

        func matchesDeletionCandidate(_ candidate: SourceFenceEntry) -> Bool {
            guard relativePath == candidate.relativePath,
                  kind == candidate.kind,
                  device == candidate.device,
                  inode == candidate.inode,
                  mode == candidate.mode,
                  owner == candidate.owner,
                  group == candidate.group else { return false }
            // Removing children necessarily changes directory size and timestamps.
            // Directory identity remains fenced and a concurrent new child makes
            // the later rmdir fail closed. Files and links retain the full fence.
            guard kind != .directory else { return true }
            return linkCount == candidate.linkCount
                && size == candidate.size
                && modifiedSeconds == candidate.modifiedSeconds
                && modifiedNanoseconds == candidate.modifiedNanoseconds
                && changedSeconds == candidate.changedSeconds
                && changedNanoseconds == candidate.changedNanoseconds
                && contentSHA256 == candidate.contentSHA256
        }

        func matchesAfterRemovingSiblingLink(
            _ candidate: SourceFenceEntry,
            expectedLinkCount: UInt64
        ) -> Bool {
            relativePath == candidate.relativePath
                && kind == candidate.kind
                && device == candidate.device
                && inode == candidate.inode
                && mode == candidate.mode
                && owner == candidate.owner
                && group == candidate.group
                && candidate.linkCount == expectedLinkCount
                && size == candidate.size
                && modifiedSeconds == candidate.modifiedSeconds
                && modifiedNanoseconds == candidate.modifiedNanoseconds
                && contentSHA256 == candidate.contentSHA256
        }

        func updatingLinkState(
            linkCount: UInt64,
            changedSeconds: Int64,
            changedNanoseconds: Int64
        ) -> SourceFenceEntry {
            SourceFenceEntry(
                relativePath: relativePath,
                kind: kind,
                device: device,
                inode: inode,
                mode: mode,
                owner: owner,
                group: group,
                linkCount: linkCount,
                size: size,
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: modifiedNanoseconds,
                changedSeconds: changedSeconds,
                changedNanoseconds: changedNanoseconds,
                contentSHA256: contentSHA256
            )
        }
    }

    private struct SourceFenceIdentity: Hashable {
        let device: Int64
        let inode: UInt64
    }

    private struct HardLinkGroupState {
        var remainingPaths: Set<String>
        var linkCount: UInt64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }

    private struct SourceFenceContentEntry: Equatable {
        let relativePath: String
        let kind: SourceFenceKind
        let permissions: UInt32
        let size: Int64
        let contentSHA256: String?
    }

    private struct SourceFence: Equatable {
        let entries: [SourceFenceEntry]

        var copiedContent: [SourceFenceContentEntry] {
            entries.map(\.copiedContent)
        }

        var entriesByRelativePath: [String: SourceFenceEntry] {
            Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        }

        var hardLinkGroups: [SourceFenceIdentity: HardLinkGroupState] {
            var groups: [SourceFenceIdentity: HardLinkGroupState] = [:]
            for entry in entries where entry.kind != .directory && entry.linkCount > 1 {
                let identity = SourceFenceIdentity(device: entry.device, inode: entry.inode)
                if var group = groups[identity] {
                    group.remainingPaths.insert(entry.relativePath)
                    groups[identity] = group
                } else {
                    groups[identity] = HardLinkGroupState(
                        remainingPaths: [entry.relativePath],
                        linkCount: entry.linkCount,
                        changedSeconds: entry.changedSeconds,
                        changedNanoseconds: entry.changedNanoseconds
                    )
                }
            }
            return groups.filter { $0.value.remainingPaths.count > 1 }
        }
    }

    private enum SourceFenceError: Error, LocalizedError {
        case changed
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .changed:
                return "The move source changed while its cross-volume copy was being reconciled"
            case .unsupported(let path):
                return "The move source contains an unsupported filesystem entry: \(path)"
            }
        }
    }

    private final class PinnedFileDescriptor {
        let rawValue: Int32

        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            _ = Darwin.close(rawValue)
        }
    }

    private struct PinnedPathParent {
        let directory: PinnedFileDescriptor
        let entryName: String
        let path: URL
        let identity: PathIdentity
    }

    private struct PinnedTreeRoot {
        let parent: PinnedPathParent
        let directory: PinnedFileDescriptor?
    }

    private struct PinnedDeletionTree {
        let plan: [DeletionEntry]
        let root: PinnedTreeRoot
        let expectedIdentities: [String: PathIdentity]
    }

    private struct PinnedRenameReceipt {
        let sourceParent: PinnedPathParent
        let destinationParent: PinnedPathParent
        let requestedNamespaceStable: Bool
    }

    private static func pinnedDirectory(at directory: URL) throws -> PinnedFileDescriptor {
        let requestedDirectory = directory.standardizedFileURL
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let resolvedPointer = requestedDirectory.path.withCString {
            Darwin.realpath($0, &resolvedBuffer)
        }
        guard resolvedPointer != nil else {
            throw posixError(errno, path: requestedDirectory.path)
        }
        let resolvedPath = String(cString: resolvedBuffer)
        guard resolvedPath.hasPrefix("/") else {
            throw posixError(EINVAL, path: resolvedPath)
        }
        let rootDescriptor = "/".withCString {
            Darwin.open($0, O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard rootDescriptor >= 0 else {
            throw posixError(errno, path: "/")
        }
        var current = PinnedFileDescriptor(rootDescriptor)
        var traversedPath = ""
        for componentSlice in resolvedPath.split(separator: "/") {
            let component = String(componentSlice)
            guard !component.isEmpty, component != ".", component != ".." else {
                throw posixError(EINVAL, path: resolvedPath)
            }
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                )
            }
            traversedPath += "/" + component
            guard nextDescriptor >= 0 else {
                throw posixError(errno, path: traversedPath)
            }
            current = PinnedFileDescriptor(nextDescriptor)
        }
        return current
    }

    private static func pinnedParent(of url: URL) throws -> PinnedPathParent {
        let standardizedURL = url.standardizedFileURL
        let entryName = standardizedURL.lastPathComponent
        guard standardizedURL.path != "/",
              !entryName.isEmpty,
              entryName != ".",
              entryName != "..",
              !entryName.contains("/") else {
            throw posixError(EINVAL, path: standardizedURL.path)
        }
        let parentPath = standardizedURL.deletingLastPathComponent().standardizedFileURL
        let directory = try pinnedDirectory(at: parentPath)
        var directoryInformation = stat()
        guard Darwin.fstat(directory.rawValue, &directoryInformation) == 0 else {
            throw posixError(errno, path: parentPath.path)
        }
        return PinnedPathParent(
            directory: directory,
            entryName: entryName,
            path: parentPath,
            identity: PathIdentity(directoryInformation)
        )
    }

    private static func pinnedParentStillNamesSameDirectory(_ parent: PinnedPathParent) -> Bool {
        do {
            let current = try pinnedDirectory(at: parent.path)
            var information = stat()
            return Darwin.fstat(current.rawValue, &information) == 0
                && parent.identity.matches(information)
        } catch {
            return false
        }
    }

    private static func pinnedTreeRoot(
        at root: URL,
        expectedIdentity: PathIdentity
    ) throws -> PinnedTreeRoot {
        let parent = try pinnedParent(of: root)
        let pathInformation = try fstatatInformation(
            parentDescriptor: parent.directory.rawValue,
            entryName: parent.entryName
        )
        guard expectedIdentity.matches(pathInformation) else {
            throw SourceFenceError.changed
        }
        guard expectedIdentity.isDirectory else {
            return PinnedTreeRoot(parent: parent, directory: nil)
        }
        let rootDescriptor = parent.entryName.withCString {
            Darwin.openat(
                parent.directory.rawValue,
                $0,
                O_SEARCH | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
            )
        }
        guard rootDescriptor >= 0 else {
            throw posixError(errno, path: root.path)
        }
        let pinnedRoot = PinnedFileDescriptor(rootDescriptor)
        var openedInformation = stat()
        guard Darwin.fstat(pinnedRoot.rawValue, &openedInformation) == 0,
              expectedIdentity.matches(openedInformation) else {
            throw SourceFenceError.changed
        }
        return PinnedTreeRoot(
            parent: parent,
            directory: pinnedRoot
        )
    }

    private static func withPinnedEntryParent<Value>(
        relativePath: String,
        root: PinnedTreeRoot,
        expectedIdentities: [String: PathIdentity],
        _ operation: (Int32, String) throws -> Value
    ) throws -> Value {
        if relativePath == "." {
            return try withExtendedLifetime(root.parent.directory) {
                try operation(root.parent.directory.rawValue, root.parent.entryName)
            }
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let entryName = components.last,
              !entryName.isEmpty,
              entryName != ".",
              entryName != "..",
              let rootDirectory = root.directory else {
            throw SourceFenceError.changed
        }

        return try withExtendedLifetime(rootDirectory) {
            var currentDescriptor = rootDirectory.rawValue
            var ownedDirectory: PinnedFileDescriptor?
            var traversed: [String] = []
            for component in components.dropLast() {
                guard !component.isEmpty, component != ".", component != ".." else {
                    throw SourceFenceError.changed
                }
                traversed.append(component)
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                    )
                }
                guard nextDescriptor >= 0 else { throw SourceFenceError.changed }
                let nextDirectory = PinnedFileDescriptor(nextDescriptor)
                var directoryInformation = stat()
                let traversedPath = traversed.joined(separator: "/")
                guard Darwin.fstat(nextDirectory.rawValue, &directoryInformation) == 0,
                      let expected = expectedIdentities[traversedPath],
                      expected.isDirectory,
                      expected.matches(directoryInformation) else {
                    throw SourceFenceError.changed
                }
                ownedDirectory = nextDirectory
                currentDescriptor = nextDirectory.rawValue
            }
            return try withExtendedLifetime(ownedDirectory) {
                try operation(currentDescriptor, entryName)
            }
        }
    }

    private static func fstatatInformation(
        parentDescriptor: Int32,
        entryName: String
    ) throws -> stat {
        var information = stat()
        let result = entryName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw posixError(errno, path: entryName)
        }
        return information
    }

    private static func fstatatInformationIfExists(
        parentDescriptor: Int32,
        entryName: String
    ) throws -> stat? {
        var information = stat()
        let result = entryName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw posixError(errno, path: entryName)
        }
        return information
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private static func recursiveDeletionPlan(
        at root: URL,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval? = nil
    ) throws -> [DeletionEntry] {
        try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
        let standardizedRoot = root.standardizedFileURL
        guard let rootInformation = try lstatInformationIfExists(at: standardizedRoot) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rootEntry = DeletionEntry(
            url: standardizedRoot,
            relativePath: ".",
            identity: PathIdentity(rootInformation)
        )
        guard rootEntry.isDirectory else {
            return [rootEntry]
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries: [DeletionEntry] = []
        entries.reserveCapacity(min(1_024, Self.maximumRecursiveMutationEntries))
        while let child = enumerator.nextObject() as? URL {
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            let standardizedChild = child.standardizedFileURL
            guard let childInformation = try lstatInformationIfExists(at: standardizedChild) else {
                continue
            }
            let entry = DeletionEntry(
                url: standardizedChild,
                relativePath: try sourceRelativePath(for: standardizedChild, root: standardizedRoot),
                identity: PathIdentity(childInformation)
            )
            if !entry.isDirectory { enumerator.skipDescendants() }
            entries.append(entry)
            if entries.count == Self.maximumRecursiveMutationEntries - 1 {
                guard enumerator.nextObject() == nil else {
                    throw FilesystemMutationError.entryLimitExceeded
                }
                break
            }
        }
        if let enumerationError { throw enumerationError }
        entries.append(rootEntry)
        entries.sort {
            let leftDepth = $0.url.pathComponents.count
            let rightDepth = $1.url.pathComponents.count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            if $0.isDirectory != $1.isDirectory { return !$0.isDirectory }
            return $0.url.path > $1.url.path
        }
        return entries
    }

    private static func pinnedDeletionTree(
        at root: URL,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval
    ) throws -> PinnedDeletionTree {
        let plan = try recursiveDeletionPlan(
            at: root,
            cancellation: cancellation,
            deadline: deadline
        )
        guard let rootEntry = plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        let expectedIdentities = Dictionary(
            uniqueKeysWithValues: plan.map { ($0.relativePath, $0.identity) }
        )
        return PinnedDeletionTree(
            plan: plan,
            root: try pinnedTreeRoot(at: root, expectedIdentity: rootEntry.identity),
            expectedIdentities: expectedIdentities
        )
    }

    private static func pinnedDeletionTreeExists(_ tree: PinnedDeletionTree) throws -> Bool {
        guard let rootEntry = tree.plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        guard let information = try fstatatInformationIfExists(
            parentDescriptor: tree.root.parent.directory.rawValue,
            entryName: tree.root.parent.entryName
        ) else { return false }
        return rootEntry.identity.matches(information)
    }

    private static func conservativelyPinnedDeletionTreeExists(_ tree: PinnedDeletionTree) -> Bool {
        (try? pinnedDeletionTreeExists(tree)) ?? true
    }

    private static func discardPinnedDeletionTree(
        _ tree: PinnedDeletionTree,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        stepObserver: (@Sendable (MoveStep) -> Void)?
    ) throws {
        do {
            for (index, entry) in tree.plan.enumerated() {
                try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
                try removeEntry(
                    entry,
                    root: tree.root,
                    expectedIdentities: tree.expectedIdentities
                )
                stepObserver?(.removedStagingEntry(index + 1))
            }
        } catch {
            _ = try? synchronizePinnedDirectory(tree.root.parent)
            throw error
        }
        try synchronizePinnedDirectory(tree.root.parent)
    }

    private static func discardPublishedStagingRoot(
        _ tree: PinnedDeletionTree,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        stepObserver: (@Sendable (MoveStep) -> Void)?
    ) throws {
        try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
        guard let rootEntry = tree.plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        try removeEntry(
            rootEntry,
            root: tree.root,
            expectedIdentities: tree.expectedIdentities
        )
        stepObserver?(.removedStagingEntry(1))
        try synchronizePinnedDirectory(tree.root.parent)
    }

    private static func checkMutationBoundary(
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval?
    ) throws {
        try cancellation?.checkCancellation()
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            throw ToolCallDeadlineExceeded()
        }
    }

    private static func captureSourceFence(
        at root: URL,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval
    ) throws -> SourceFence {
        let standardizedRoot = root.standardizedFileURL
        let plan = try recursiveDeletionPlan(
            at: standardizedRoot,
            cancellation: cancellation,
            deadline: deadline
        )
        guard let rootEntry = plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        let expectedIdentities = Dictionary(
            uniqueKeysWithValues: plan.map { ($0.relativePath, $0.identity) }
        )
        let pinnedRoot = try pinnedTreeRoot(
            at: standardizedRoot,
            expectedIdentity: rootEntry.identity
        )
        var entries: [SourceFenceEntry] = []
        entries.reserveCapacity(plan.count)
        for deletionEntry in plan.sorted(by: { $0.relativePath < $1.relativePath }) {
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            entries.append(try withPinnedEntryParent(
                relativePath: deletionEntry.relativePath,
                root: pinnedRoot,
                expectedIdentities: expectedIdentities
            ) { parentDescriptor, entryName in
                try captureSourceFenceEntry(
                    parentDescriptor: parentDescriptor,
                    entryName: entryName,
                    displayPath: deletionEntry.url.path,
                    relativePath: deletionEntry.relativePath,
                    cancellation: cancellation,
                    deadline: deadline
                )
            })
        }
        return SourceFence(entries: entries)
    }

    private static func verifiedSourceFence(
        at root: URL,
        expected: SourceFence,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval
    ) throws {
        do {
            let actual = try captureSourceFence(
                at: root,
                cancellation: cancellation,
                deadline: deadline
            )
            guard actual == expected else { throw SourceFenceError.changed }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            throw SourceFenceError.changed
        }
    }

    private static func removeVerifiedDeletionCandidate(
        _ deletionEntry: DeletionEntry,
        pinnedRoot: PinnedTreeRoot,
        expectedByRelativePath: [String: SourceFenceEntry],
        expectedIdentities: [String: PathIdentity],
        hardLinkGroups: [SourceFenceIdentity: HardLinkGroupState],
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        beforeRemoval: () -> Void
    ) throws -> String {
        do {
            let relativePath = deletionEntry.relativePath
            guard let recorded = expectedByRelativePath[relativePath] else {
                throw SourceFenceError.changed
            }
            let expected: SourceFenceEntry
            if recorded.linkCount == 1 {
                // The common case performs no hard-link group lookup or manifest scan.
                expected = recorded
            } else {
                let identity = SourceFenceIdentity(
                    device: recorded.device,
                    inode: recorded.inode
                )
                if let group = hardLinkGroups[identity] {
                    expected = recorded.updatingLinkState(
                        linkCount: group.linkCount,
                        changedSeconds: group.changedSeconds,
                        changedNanoseconds: group.changedNanoseconds
                    )
                } else {
                    expected = recorded
                }
            }
            return try withPinnedEntryParent(
                relativePath: relativePath,
                root: pinnedRoot,
                expectedIdentities: expectedIdentities
            ) { parentDescriptor, entryName in
                beforeRemoval()
                let actual = try captureSourceFenceEntry(
                    parentDescriptor: parentDescriptor,
                    entryName: entryName,
                    displayPath: deletionEntry.url.path,
                    relativePath: relativePath,
                    cancellation: cancellation,
                    deadline: deadline
                )
                guard expected.matchesDeletionCandidate(actual) else {
                    throw SourceFenceError.changed
                }
                let flags = deletionEntry.isDirectory
                    ? AT_REMOVEDIR
                    : 0
                let result = entryName.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, flags)
                }
                guard result == 0 else {
                    throw posixError(errno, path: deletionEntry.url.path)
                }
                return relativePath
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            throw SourceFenceError.changed
        }
    }

    private static func reconcileExpectedLinkStateAfterRemoval(
        removedRelativePath: String,
        sourceRoot: URL,
        pinnedRoot: PinnedTreeRoot,
        expectedIdentities: [String: PathIdentity],
        expectedByRelativePath: inout [String: SourceFenceEntry],
        hardLinkGroups: inout [SourceFenceIdentity: HardLinkGroupState],
        stepObserver: (@Sendable (MoveStep) -> Void)?,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval
    ) throws {
        let standardizedRoot = sourceRoot.standardizedFileURL
        guard let removed = expectedByRelativePath.removeValue(forKey: removedRelativePath),
              removed.kind != .directory,
              removed.linkCount > 1 else { return }
        let identity = SourceFenceIdentity(device: removed.device, inode: removed.inode)
        guard var group = hardLinkGroups[identity] else { return }
        group.remainingPaths.remove(removedRelativePath)
        guard let representativePath = group.remainingPaths.first,
              group.linkCount > 0 else {
            hardLinkGroups.removeValue(forKey: identity)
            return
        }
        stepObserver?(.reconcilingHardLinkGroup)
        let representativeURL = representativePath == "."
            ? standardizedRoot
            : standardizedRoot.appendingPathComponent(representativePath)
        let actual = try withPinnedEntryParent(
            relativePath: representativePath,
            root: pinnedRoot,
            expectedIdentities: expectedIdentities
        ) { parentDescriptor, entryName in
            try captureSourceFenceEntry(
                parentDescriptor: parentDescriptor,
                entryName: entryName,
                displayPath: representativeURL.path,
                relativePath: representativePath,
                cancellation: cancellation,
                deadline: deadline
            )
        }
        let expectedLinkCount = group.linkCount - 1
        guard let recordedRepresentative = expectedByRelativePath[representativePath] else {
            throw SourceFenceError.changed
        }
        let representative = recordedRepresentative.updatingLinkState(
            linkCount: group.linkCount,
            changedSeconds: group.changedSeconds,
            changedNanoseconds: group.changedNanoseconds
        )
        guard representative.matchesAfterRemovingSiblingLink(
            actual,
            expectedLinkCount: expectedLinkCount
        ) else {
            throw SourceFenceError.changed
        }
        // The unlink necessarily changes inode ctime. A concurrent metadata-only
        // mutation in the narrow unlink-to-refresh interval is indistinguishable
        // from that kernel update and remains an explicit E2 residual.
        group.linkCount = actual.linkCount
        group.changedSeconds = actual.changedSeconds
        group.changedNanoseconds = actual.changedNanoseconds
        hardLinkGroups[identity] = group
    }

    private static func captureSourceFenceEntry(
        parentDescriptor: Int32,
        entryName: String,
        displayPath: String,
        relativePath: String,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval
    ) throws -> SourceFenceEntry {
        try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
        let initialPathInformation = try fstatatInformation(
            parentDescriptor: parentDescriptor,
            entryName: entryName
        )
        let kindBits = initialPathInformation.st_mode & S_IFMT

        if kindBits == S_IFDIR {
            let finalPathInformation = try fstatatInformation(
                parentDescriptor: parentDescriptor,
                entryName: entryName
            )
            guard stableMetadataMatches(initialPathInformation, finalPathInformation) else {
                throw SourceFenceError.changed
            }
            return sourceFenceEntry(
                relativePath: relativePath,
                kind: .directory,
                information: finalPathInformation,
                contentSHA256: nil
            )
        }

        if kindBits == S_IFLNK {
            var target = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = target.withUnsafeMutableBytes { bytes in
                entryName.withCString {
                    Darwin.readlinkat(parentDescriptor, $0, bytes.baseAddress, bytes.count)
                }
            }
            guard count >= 0, count < target.count else {
                throw SourceFenceError.changed
            }
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            let finalPathInformation = try fstatatInformation(
                parentDescriptor: parentDescriptor,
                entryName: entryName
            )
            guard stableMetadataMatches(initialPathInformation, finalPathInformation),
                  Int64(count) == finalPathInformation.st_size else {
                throw SourceFenceError.changed
            }
            let digest = SHA256.hash(data: Data(target.prefix(count)))
                .map { String(format: "%02x", $0) }
                .joined()
            return sourceFenceEntry(
                relativePath: relativePath,
                kind: .symbolicLink,
                information: finalPathInformation,
                contentSHA256: digest
            )
        }

        guard kindBits == S_IFREG else {
            throw SourceFenceError.unsupported(displayPath)
        }
        let descriptor = entryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
            )
        }
        guard descriptor >= 0 else { throw SourceFenceError.changed }
        defer { _ = Darwin.close(descriptor) }

        var openedInformation = stat()
        guard Darwin.fstat(descriptor, &openedInformation) == 0,
              openedInformation.st_mode & S_IFMT == S_IFREG,
              openedInformation.st_size >= 0,
              stableMetadataMatches(initialPathInformation, openedInformation) else {
            throw SourceFenceError.changed
        }

        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while consumed < openedInformation.st_size {
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            let requested = min(buffer.count, Int(openedInformation.st_size - consumed))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SourceFenceError.changed }
            hasher.update(data: Data(buffer.prefix(count)))
            consumed += Int64(count)
        }

        var finalDescriptorInformation = stat()
        guard Darwin.fstat(descriptor, &finalDescriptorInformation) == 0,
              stableMetadataMatches(openedInformation, finalDescriptorInformation) else {
            throw SourceFenceError.changed
        }
        let finalPathInformation = try fstatatInformation(
            parentDescriptor: parentDescriptor,
            entryName: entryName
        )
        guard stableMetadataMatches(finalDescriptorInformation, finalPathInformation) else {
            throw SourceFenceError.changed
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return sourceFenceEntry(
            relativePath: relativePath,
            kind: .regular,
            information: finalDescriptorInformation,
            contentSHA256: digest
        )
    }

    private static func sourceFenceEntry(
        relativePath: String,
        kind: SourceFenceKind,
        information: stat,
        contentSHA256: String?
    ) -> SourceFenceEntry {
        SourceFenceEntry(
            relativePath: relativePath,
            kind: kind,
            device: Int64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            owner: UInt32(information.st_uid),
            group: UInt32(information.st_gid),
            linkCount: UInt64(information.st_nlink),
            size: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changedSeconds: Int64(information.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(information.st_ctimespec.tv_nsec),
            contentSHA256: contentSHA256
        )
    }

    private static func stableMetadataMatches(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func lstatInformation(at url: URL) throws -> stat {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return information
    }

    private static func lstatInformationIfExists(at url: URL) throws -> stat? {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError(errno, path: url.path)
        }
        return information
    }

    private static func sourceRelativePath(for url: URL, root: URL) throws -> String {
        if url.path == root.path { return "." }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw SourceFenceError.changed }
        return String(url.path.dropFirst(prefix.count))
    }

    private func createDurableDirectoryHierarchy(
        at directory: URL,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        var missing: [URL] = []
        var ancestor = directory.standardizedFileURL
        var ancestorIsDirectory: ObjCBool = false
        while !FileManager.default.fileExists(
            atPath: ancestor.path,
            isDirectory: &ancestorIsDirectory
        ) {
            try cancellation?.checkCancellation()
            guard ancestor.path != "/" else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOENT),
                    userInfo: [NSFilePathErrorKey: directory.path]
                )
            }
            missing.append(ancestor)
            ancestor.deleteLastPathComponent()
        }
        guard ancestorIsDirectory.boolValue else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOTDIR),
                userInfo: [NSFilePathErrorKey: ancestor.path]
            )
        }

        var created: [URL] = []
        do {
            for component in missing.reversed() {
                try cancellation?.checkCancellation()
                let result = component.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
                if result != 0 {
                    let createCode = errno
                    guard createCode == EEXIST,
                          (try Self.itemType(at: component)).isDirectory else {
                        throw NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(createCode),
                            userInfo: [NSFilePathErrorKey: component.path]
                        )
                    }
                    continue
                }
                created.append(component)
                guard component.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSFilePathErrorKey: component.path]
                    )
                }
                try directorySynchronizer(component)
                try directorySynchronizer(component.deletingLastPathComponent())
            }
            return created
        } catch {
            throw DirectoryHierarchyFailure(createdDirectories: created, underlying: error)
        }
    }

    private func synchronizeMoveParents(source: URL, destination: URL) throws {
        let sourceParent = source.deletingLastPathComponent().standardizedFileURL
        let destinationParent = destination.deletingLastPathComponent().standardizedFileURL
        var parents = [destinationParent]
        if sourceParent.path != destinationParent.path { parents.append(sourceParent) }
        for parent in parents { try directorySynchronizer(parent) }
    }

    private static func committedMoveResult(
        source: URL,
        destination: URL,
        durabilityConfirmed: Bool,
        durabilityError: Error?,
        movedEntries: Int? = nil
    ) -> ToolResult {
        var payload: [String: Any] = [
            "ok": true,
            "src": source.path,
            "dest": destination.path,
            "source_exists": pathEntryExists(source),
            "destination_exists": pathEntryExists(destination),
            "committed": true,
            "durability_confirmed": durabilityConfirmed,
        ]
        if let movedEntries { payload["moved_entries"] = movedEntries }
        if let durabilityError {
            payload["durability_error"] = durabilityError.localizedDescription
            payload["reconciled"] = true
        }
        return ToolResult(ok: true, payload: payload, isError: false)
    }

    private static func namespaceChangedAfterRenameResult(
        source: URL,
        destination: URL,
        completedEntries: Int,
        durabilityConfirmed: Bool,
        createdDirectories: [URL]
    ) -> ToolResult {
        var result = partialMoveResult(
            source: source,
            destination: destination,
            completedEntries: completedEntries,
            error: SourceFenceError.changed,
            destinationComplete: false,
            createdDirectories: createdDirectories
        )
        result.payload["committed"] = true
        result.payload["requested_namespace_stable"] = false
        result.payload["durability_confirmed"] = durabilityConfirmed
        return result
    }

    private static func itemType(at url: URL) throws -> (exists: Bool, isDirectory: Bool) {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return (false, false) }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return (true, information.st_mode & S_IFMT == S_IFDIR)
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        (try? itemType(at: url).exists) == true
    }

    private static func removeEntry(
        _ entry: DeletionEntry,
        root: PinnedTreeRoot,
        expectedIdentities: [String: PathIdentity],
        beforeRemoval: () -> Void = {}
    ) throws {
        try withPinnedEntryParent(
            relativePath: entry.relativePath,
            root: root,
            expectedIdentities: expectedIdentities
        ) { parentDescriptor, entryName in
            beforeRemoval()
            let information = try fstatatInformation(
                parentDescriptor: parentDescriptor,
                entryName: entryName
            )
            guard entry.identity.matches(information) else {
                throw SourceFenceError.changed
            }
            let flags = entry.isDirectory
                ? AT_REMOVEDIR
                : 0
            let result = entryName.withCString {
                Darwin.unlinkat(parentDescriptor, $0, flags)
            }
            guard result == 0 else {
                throw posixError(errno, path: entry.url.path)
            }
        }
    }

    private static func renameExclusively(
        source: URL,
        destination: URL,
        expectedSourceIdentity: PathIdentity,
        beforeRename: () throws -> Void
    ) throws -> PinnedRenameReceipt {
        let sourceParent = try pinnedParent(of: source)

        func performRename(destinationParent: PinnedPathParent) throws -> PinnedRenameReceipt {
            try beforeRename()
            guard pinnedParentStillNamesSameDirectory(sourceParent),
                  pinnedParentStillNamesSameDirectory(destinationParent) else {
                throw SourceFenceError.changed
            }
            let sourceInformation = try fstatatInformation(
                parentDescriptor: sourceParent.directory.rawValue,
                entryName: sourceParent.entryName
            )
            guard expectedSourceIdentity.matches(sourceInformation) else {
                throw SourceFenceError.changed
            }
            let result = sourceParent.entryName.withCString { sourceName in
                destinationParent.entryName.withCString { destinationName in
                    Darwin.renameatx_np(
                        sourceParent.directory.rawValue,
                        sourceName,
                        destinationParent.directory.rawValue,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                throw posixError(errno, path: destination.path)
            }
            let destinationIdentityMatches: Bool
            do {
                destinationIdentityMatches = expectedSourceIdentity.matches(
                    try fstatatInformation(
                        parentDescriptor: destinationParent.directory.rawValue,
                        entryName: destinationParent.entryName
                    )
                )
            } catch {
                destinationIdentityMatches = false
            }
            let sourceNameIsVacant: Bool
            do {
                sourceNameIsVacant = try fstatatInformationIfExists(
                    parentDescriptor: sourceParent.directory.rawValue,
                    entryName: sourceParent.entryName
                ) == nil
            } catch {
                sourceNameIsVacant = false
            }
            let requestedNamespaceStable = pinnedParentStillNamesSameDirectory(sourceParent)
                && pinnedParentStillNamesSameDirectory(destinationParent)
                && destinationIdentityMatches
                && sourceNameIsVacant
            return PinnedRenameReceipt(
                sourceParent: sourceParent,
                destinationParent: destinationParent,
                requestedNamespaceStable: requestedNamespaceStable
            )
        }

        if sourceParent.path == destination.deletingLastPathComponent().standardizedFileURL {
            let destinationParent = PinnedPathParent(
                directory: sourceParent.directory,
                entryName: destination.lastPathComponent,
                path: sourceParent.path,
                identity: sourceParent.identity
            )
            return try performRename(destinationParent: destinationParent)
        } else {
            return try performRename(destinationParent: pinnedParent(of: destination))
        }
    }

    private static func synchronizePinnedRenameParents(_ receipt: PinnedRenameReceipt) throws {
        try synchronizePinnedDirectory(receipt.destinationParent)
        if receipt.sourceParent.identity != receipt.destinationParent.identity {
            try synchronizePinnedDirectory(receipt.sourceParent)
        }
    }

    private static func synchronizePinnedDirectory(_ parent: PinnedPathParent) throws {
        guard Darwin.fsync(parent.directory.rawValue) == 0 else {
            throw posixError(errno, path: parent.path.path)
        }
    }

    private static func synchronizeTree(
        at root: URL,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        stepObserver: (@Sendable (MoveStep) -> Void)?
    ) throws {
        let plan = try recursiveDeletionPlan(
            at: root,
            cancellation: cancellation,
            deadline: deadline
        )
        // The deletion plan is deepest-first; syncing in that order persists file
        // contents before their containing directory entries.
        for (index, entry) in plan.enumerated() {
            stepObserver?(.synchronizingStagingEntry(index + 1))
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            var information = stat()
            guard entry.url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: entry.url.path]
                )
            }
            let kind = information.st_mode & S_IFMT
            if kind == S_IFLNK { continue }
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOTSUP),
                    userInfo: [NSFilePathErrorKey: entry.url.path]
                )
            }
            let flags = entry.isDirectory
                ? O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                : O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            let descriptor = entry.url.path.withCString { Darwin.open($0, flags) }
            guard descriptor >= 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: entry.url.path]
                )
            }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: entry.url.path]
                )
            }
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
    }

    private static func discardPrivateStaging(
        at staging: URL,
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        stepObserver: (@Sendable (MoveStep) -> Void)?
    ) throws {
        guard pathEntryExists(staging) else { return }
        try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
        let plan = try recursiveDeletionPlan(
            at: staging,
            cancellation: cancellation,
            deadline: deadline
        )
        guard let rootEntry = plan.first(where: { $0.relativePath == "." }) else {
            throw SourceFenceError.changed
        }
        let expectedIdentities = Dictionary(
            uniqueKeysWithValues: plan.map { ($0.relativePath, $0.identity) }
        )
        let pinnedRoot = try pinnedTreeRoot(
            at: staging,
            expectedIdentity: rootEntry.identity
        )
        for (index, entry) in plan.enumerated() {
            try checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            try removeEntry(
                entry,
                root: pinnedRoot,
                expectedIdentities: expectedIdentities
            )
            stepObserver?(.removedStagingEntry(index + 1))
        }
    }

    private func stagingFailureResult(
        source: URL,
        destination: URL,
        stagingRoot: URL,
        error: Error,
        createdDestinationDirectories: [URL],
        cancellation: ToolCallCancellation?,
        deadline: TimeInterval,
        pinnedStagingTree: PinnedDeletionTree? = nil
    ) throws -> ToolResult {
        let stagingExistedBeforeCleanup = pinnedStagingTree.map(Self.conservativelyPinnedDeletionTreeExists)
            ?? Self.pathEntryExists(stagingRoot)
        do {
            if stagingExistedBeforeCleanup {
                if let pinnedStagingTree {
                    try Self.discardPinnedDeletionTree(
                        pinnedStagingTree,
                        cancellation: cancellation,
                        deadline: deadline,
                        stepObserver: moveStepObserver
                    )
                } else {
                    try Self.discardPrivateStaging(
                        at: stagingRoot,
                        cancellation: cancellation,
                        deadline: deadline,
                        stepObserver: moveStepObserver
                    )
                }
                try Self.checkMutationBoundary(cancellation: cancellation, deadline: deadline)
                try directorySynchronizer(destination.deletingLastPathComponent())
                try Self.checkMutationBoundary(cancellation: cancellation, deadline: deadline)
            }
        } catch let cleanupError {
            let reportedError: Error
            if cleanupError is CancellationError || cleanupError is ToolCallDeadlineExceeded {
                reportedError = cleanupError
            } else {
                reportedError = error
            }
            var result = Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: createdDestinationDirectories.count,
                error: reportedError,
                createdDirectories: createdDestinationDirectories
            )
            result.payload["staging_path"] = stagingRoot.path
            let stagingExists = pinnedStagingTree.map(Self.conservativelyPinnedDeletionTreeExists)
                ?? Self.pathEntryExists(stagingRoot)
            result.payload["staging_cleanup_required"] = stagingExists
            result.payload["staging_exists"] = stagingExists
            result.payload["staging_cleanup_error"] = cleanupError.localizedDescription
            return result
        }
        if !createdDestinationDirectories.isEmpty {
            return Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: createdDestinationDirectories.count,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }
        if error is CancellationError { throw CancellationError() }
        if let deadline = error as? ToolCallDeadlineExceeded { throw deadline }
        if error is SourceFenceError {
            return .failure(
                code: "source_changed",
                message: error.localizedDescription,
                retryable: false
            )
        }
        return .failure(
            code: "move_failed",
            message: error.localizedDescription,
            retryable: false
        )
    }

    private func prepublicationMoveFailureResult(
        source: URL,
        destination: URL,
        error: Error,
        createdDestinationDirectories: [URL]
    ) throws -> ToolResult {
        if !createdDestinationDirectories.isEmpty {
            return Self.partialMoveResult(
                source: source,
                destination: destination,
                completedEntries: createdDestinationDirectories.count,
                error: error,
                createdDirectories: createdDestinationDirectories
            )
        }
        if error is CancellationError { throw CancellationError() }
        if let deadline = error as? ToolCallDeadlineExceeded { throw deadline }
        if error is SourceFenceError {
            return .failure(
                code: "source_changed",
                message: error.localizedDescription,
                retryable: false
            )
        }
        return .failure(code: "move_failed", message: error.localizedDescription)
    }

    private static func partialMoveResult(
        source: URL,
        destination: URL,
        completedEntries: Int,
        error: Error,
        destinationComplete: Bool = false,
        createdDirectories: [URL]
    ) -> ToolResult {
        var result = partialMutationResult(
            operation: "move",
            source: source,
            destination: destination,
            completedEntries: completedEntries,
            error: error,
            destinationComplete: destinationComplete
        )
        if !createdDirectories.isEmpty {
            result.payload["created_directories"] = createdDirectories.map(\.path)
        }
        return result
    }

    private static func sourceFencePartialResult(
        source: URL,
        destination: URL,
        completedEntries: Int,
        error: Error,
        createdDirectories: [URL]
    ) -> ToolResult {
        let reportedError: Error
        if error is CancellationError || error is ToolCallDeadlineExceeded {
            reportedError = error
        } else {
            reportedError = SourceFenceError.changed
        }
        var result = partialMoveResult(
            source: source,
            destination: destination,
            completedEntries: completedEntries,
            error: reportedError,
            destinationComplete: true,
            createdDirectories: createdDirectories
        )
        result.payload["source_fence_verified"] = false
        result.payload["source_preserved"] = pathEntryExists(source)
        return result
    }

    private static func partialMutationResult(
        operation: String,
        source: URL,
        destination: URL?,
        completedEntries: Int,
        error: Error,
        destinationComplete: Bool = false
    ) -> ToolResult {
        let controlCode: String
        if error is CancellationError {
            controlCode = "request_cancelled"
        } else if error is ToolCallDeadlineExceeded {
            controlCode = "deadline_exceeded"
        } else if error is SourceFenceError {
            controlCode = "source_changed"
        } else {
            controlCode = "filesystem_error"
        }
        var payload: [String: Any] = [
            "ok": false,
            "code": "partial_filesystem_mutation",
            "message": "The \(operation) stopped after changing part of the requested filesystem state",
            "retryable": false,
            "operation": operation,
            "source": source.path,
            "completed_entries": completedEntries,
            "control_code": controlCode,
            "source_exists": pathEntryExists(source),
            "reconciled": true,
        ]
        if let destination {
            payload["destination"] = destination.path
            payload["destination_exists"] = pathEntryExists(destination)
            payload["destination_complete"] = destinationComplete
        }
        return ToolResult(ok: false, payload: payload, isError: true)
    }

    private enum BoundedTextReadError: Error {
        case tooLarge
        case unreadable
    }

    /// Opens nonblocking so special files cannot strand the transport thread, then
    /// accepts only regular files and enforces the byte cap on the bytes actually
    /// read. The post-open size check closes the stat/read replacement race.
    private static func readBoundedUTF8Text(
        at url: URL,
        cancellation: ToolCallCancellation?
    ) throws -> (Data, String) {
        try cancellation?.checkCancellation()
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw BoundedTextReadError.unreadable }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw BoundedTextReadError.unreadable
        }
        guard information.st_size >= 0,
              information.st_size <= Self.maximumTextFileBytes else {
            throw BoundedTextReadError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(information.st_size), Self.maximumTextFileBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= Self.maximumTextFileBytes {
            try cancellation?.checkCancellation()
            let remaining = Self.maximumTextFileBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw BoundedTextReadError.unreadable
        }
        guard data.count <= Self.maximumTextFileBytes else {
            throw BoundedTextReadError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BoundedTextReadError.unreadable
        }
        try cancellation?.checkCancellation()
        return (data, text)
    }
}

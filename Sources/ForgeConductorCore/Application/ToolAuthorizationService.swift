// ToolAuthorizationService.swift
// What: Enforces agent grants and normalizes native filesystem paths.
// How: It canonicalizes requested paths before dispatch, evaluates the active agent's
// policy, and sanitizes arguments before audit persistence.
// Why: Authorization must be centralized so no connector can bypass safety rules.

import Darwin
import Foundation

/// Captures the complete result of evaluating one tool invocation against policy.
///
/// Allowed calls carry normalized arguments forward to execution; denied calls carry
/// a stable machine code and a user-facing explanation back to the transport adapter.
public enum ToolAuthorizationDecision {
    case allowed(arguments: [String: Any])
    case denied(code: String, message: String)
}

/// Centralizes additive grant semantics for tools that are required to safely
/// finish an operation already authorized by another tool. An explicit recovery
/// grant remains narrower and never grants a new delete.
enum ToolGrantSemantics {
    private static let protectedDelete = "fs_delete"
    private static let protectedDeleteRecovery = "fs_delete_recovery"

    static func grants<C: Collection>(
        tool: String,
        from grantedTools: C
    ) -> Bool where C.Element == String {
        grantedTools.contains("*")
            || grantedTools.contains(tool)
            || (tool == protectedDeleteRecovery && grantedTools.contains(protectedDelete))
    }

    static func forbids<C: Collection>(
        tool: String,
        from forbiddenTools: C
    ) -> Bool where C.Element == String {
        forbiddenTools.contains(tool)
            || (tool == protectedDeleteRecovery && forbiddenTools.contains(protectedDelete))
    }

    static func expanded(_ grantedTools: Set<String>) -> Set<String> {
        guard grantedTools.contains(protectedDelete) else { return grantedTools }
        var expanded = grantedTools
        expanded.insert(protectedDeleteRecovery)
        return expanded
    }
}

/// Defines the authorization boundary that every tool call must cross before routing.
public protocol ToolAuthorizing: Sendable {
    func authorize(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision
    func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision
    func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolAuthorizationDecision
}

public extension ToolAuthorizing {
    func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision {
        authorize(tool: tool, arguments: arguments, clientID: clientID, binding: binding)
    }

    func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolAuthorizationDecision {
        try cancellation?.checkCancellation()
        let decision = authorize(
            tool: tool,
            arguments: arguments,
            context: context,
            clientID: clientID,
            binding: binding
        )
        try cancellation?.checkCancellation()
        return decision
    }
}

/// Final authorization boundary for every tool adapter.
///
/// Agent tool grants are enforced here so a new tool pack cannot accidentally
/// bypass policy by forgetting a local check. Workspace roots select project
/// identity and default paths; they do not confine native model tools.
public final class ToolAuthorizationService: ToolAuthorizing, @unchecked Sendable {
    private let paths: AppPaths
    private let config: ConfigStore
    private let fileManager: FileManager
    public weak var workspace: WorkspaceRootProviding?

    public init(
        paths: AppPaths,
        config: ConfigStore,
        fileManager: FileManager = .default,
        workspace: WorkspaceRootProviding? = nil
    ) {
        self.paths = paths
        self.config = config
        self.fileManager = fileManager
        self.workspace = workspace
    }

    public func authorize(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision {
        authorize(
            tool: tool,
            arguments: arguments,
            context: nil,
            clientID: clientID,
            binding: binding
        )
    }

    public func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision {
        (try? authorize(
            tool: tool,
            arguments: arguments,
            context: context,
            clientID: clientID,
            binding: binding,
            cancellation: nil
        )) ?? .denied(
            code: "authorization_unavailable",
            message: "Tool authorization state is unavailable"
        )
    }

    public func authorize(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        binding: ActiveBinding?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolAuthorizationDecision {
        try cancellation?.checkCancellation()
        if let context {
            guard context.clientID == clientID else {
                return .denied(
                    code: "project_scope_mismatch",
                    message: "Invocation client does not match the durable project context"
                )
            }
            let allowed = context.authorizationScope.allowedTools
            guard ToolGrantSemantics.grants(tool: tool, from: allowed) else {
                return .denied(
                    code: "tool_not_granted",
                    message: "Tool '\(tool)' is outside the durable project authorization scope"
                )
            }
        }
        if let binding {
            if ToolGrantSemantics.forbids(tool: tool, from: binding.toolsForbidden) {
                return .denied(
                    code: "tool_forbidden",
                    message: "Agent '\(binding.agentID)' explicitly forbids tool '\(tool)'"
                )
            }
            if !binding.toolsPrimary.isEmpty,
               !ToolGrantSemantics.grants(tool: tool, from: binding.toolsPrimary),
               !Self.sessionLifecycleTools.contains(tool) {
                return .denied(
                    code: "tool_not_granted",
                    message: "Tool '\(tool)' is not granted to agent '\(binding.agentID)'"
                )
            }
        } else if Self.requiresActiveSession.contains(tool) {
            let extras: [URL]
            if let contextualRoots = context?.authorizationScope.canonicalRoots {
                extras = contextualRoots
            } else {
                extras = try workspace?.additionalRoots(
                    for: clientID,
                    cancellation: cancellation
                ) ?? []
            }
            if extras.isEmpty {
                return .denied(
                    code: "active_session_required",
                    message: "Tool '\(tool)' requires agent_run_start with an explicit workspace cwd"
                )
            }
        }

        let shellPolicy = config.model.shell
        if Self.runtimeExecutionTools.contains(tool), !shellPolicy.enabled {
            let explicitlyDisabled = shellPolicy.userDisabled
            return .denied(
                code: explicitlyDisabled ? "shell_disabled_by_user" : "shell_disabled",
                message: explicitlyDisabled
                    ? "Project shell tools were disabled explicitly in local settings"
                    : "Project shell tools are unavailable because the configured policy is not enabled"
            )
        }

        if tool == "docx_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "DOCX path must be a nonblank string without NUL bytes"
                )
            }
        }

        if tool == "xlsx_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "XLSX path must be a nonblank string without NUL bytes"
                )
            }
        }

        if tool == "image_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "Image path must be a nonblank string without NUL bytes"
                )
            }
        }

        if tool == "audio_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(code: "invalid_path", message: "WAV path must be a nonblank string without NUL bytes")
            }
        }

        if tool == "archive_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "ZIP path must be a nonblank string without NUL bytes"
                )
            }
        }

        if tool == "ods_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "ODS path must be a nonblank string without NUL bytes"
                )
            }
        }

        if tool == "pptx_write" {
            guard let path = arguments["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !path.utf8.contains(0) else {
                return .denied(
                    code: "invalid_path",
                    message: "PPTX path must be a nonblank string without NUL bytes"
                )
            }
        }

        if let blankPathKey = Self.blankDestructivePathKey(
            tool: tool,
            arguments: arguments
        ) {
            return .denied(
                code: "invalid_path",
                message: "Destructive filesystem path '\(blankPathKey)' cannot be empty or whitespace"
            )
        }

        if tool == "fs_list", FilesystemListingPage.usesPagedMode(arguments: arguments) {
            do {
                _ = try FilesystemListingPage.Arguments(arguments)
            } catch let failure as FilesystemListingPage.Failure {
                let result = failure.result
                return .denied(code: result.payload["code"] as? String ?? "listing_invalid_argument",
                               message: result.payload["message"] as? String ?? "Invalid listing arguments")
            }
        }

        let base = try defaultBase(
            binding: binding,
            context: context,
            clientID: clientID,
            cancellation: cancellation
        )
        let protectedWorkspaceRoots = try workspaceRoots(
            binding: binding,
            context: context,
            clientID: clientID,
            cancellation: cancellation
        )
        let protectedDestructiveRoots = try destructiveRootProtections(
            workspaceRoots: protectedWorkspaceRoots,
            cancellation: cancellation
        )
        var normalized = arguments

        for access in pathAccesses(tool: tool, arguments: arguments, base: base) {
            try cancellation?.checkCancellation()
            guard access.url.path.utf8.count <= Int(PATH_MAX) else {
                return .denied(
                    code: "invalid_path",
                    message: "Path exceeds the supported filesystem limit"
                )
            }
            let candidate = try canonicalURL(
                access.url,
                preservingFinalComponent: access.preservesFinalComponent,
                cancellation: cancellation
            )
            if tool == "project_memory.initialize", candidate.path == "/" {
                return .denied(
                    code: "project_bootstrap_root_forbidden",
                    message: "The filesystem root cannot become a project authorization root"
                )
            }
            if Self.projectRegistrationTools.contains(tool) {
                let selectableRoots = try configuredProjectRoots(cancellation: cancellation)
                guard selectableRoots.contains(where: { contains(candidate, root: $0) }) else {
                    return .denied(
                        code: "path_outside_allowed_roots",
                        message: "Project registration requires a folder selected in Settings"
                    )
                }
            }
            if access.protectRoot,
               try destructiveTargetIsProtected(
                   candidate,
                   protectedRoots: protectedDestructiveRoots,
                   cancellation: cancellation
               ) {
                return .denied(
                    code: "workspace_root_protected",
                    message: "A filesystem, volume, home, manager, or active workspace root cannot be deleted or moved: \(candidate.path)"
                )
            }
            normalized[access.key] = candidate.path
        }

        if Self.cwdTools.contains(tool), normalized["cwd"] == nil {
            normalized["cwd"] = base.path
        }
        if tool == "fs_list" || tool == "fs_glob" || tool == "search_text",
           normalized["path"] == nil {
            normalized["path"] = base.path
        }
        try cancellation?.checkCancellation()
        return .allowed(arguments: normalized)
    }

    private struct PathAccess {
        var key: String
        var url: URL
        var protectRoot: Bool
        var preservesFinalComponent: Bool
    }

    /// An empty file URL resolves to the process working directory. Reject blank
    /// destructive operands before path normalization so they can never alias a
    /// protected workspace, home, manager, filesystem, or mounted-volume root.
    private static func blankDestructivePathKey(
        tool: String,
        arguments: [String: Any]
    ) -> String? {
        func firstBlankValue(for keys: [String]) -> String? {
            for key in keys {
                guard let value = ToolArgHelpers.string(arguments, key) else { continue }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? key
                    : nil
            }
            return nil
        }

        switch tool {
        case "fs_delete":
            return firstBlankValue(for: ["path"])
        case "fs_move":
            return firstBlankValue(for: ["path", "src", "source"])
                ?? firstBlankValue(for: ["dest", "destination"])
        default:
            return nil
        }
    }

    private func pathAccesses(
        tool: String,
        arguments: [String: Any],
        base: URL
    ) -> [PathAccess] {
        func access(
            _ key: String,
            protectRoot: Bool = false,
            preservesFinalComponent: Bool = false
        ) -> PathAccess? {
            guard let raw = ToolArgHelpers.string(arguments, key), !raw.isEmpty else { return nil }
            return PathAccess(
                key: key,
                url: resolve(raw, relativeTo: base),
                protectRoot: protectRoot,
                preservesFinalComponent: preservesFinalComponent
            )
        }

        switch tool {
        case "agent_run_start":
            return [access("cwd")].compactMap { $0 }
        case "project_memory.initialize":
            let projectPathKey = ["project_path", "path"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            return [
                projectPathKey.flatMap { access($0) },
            ].compactMap { $0 }
        case "fs_read":
            return [access("path")].compactMap { $0 }
        case "fs_write", "fs_edit", "fs_mkdir":
            return [access("path")].compactMap { $0 }
        case "fs_list", "fs_glob", "search_text":
            return [
                access("path") ?? PathAccess(
                    key: "path",
                    url: base,
                    protectRoot: false,
                    preservesFinalComponent: false
                ),
            ]
        case "fs_delete":
            return [access(
                "path",
                protectRoot: true,
                preservesFinalComponent: true
            )].compactMap { $0 }
        case "fs_move":
            let sourceKey = ["path", "src", "source"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            let destinationKey = ["dest", "destination"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            return [
                sourceKey.flatMap {
                    access(
                        $0,
                        protectRoot: true,
                        preservesFinalComponent: true
                    )
                },
                destinationKey.flatMap {
                    access($0, preservesFinalComponent: true)
                },
            ].compactMap { $0 }
        case "pdf_write", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write", "archive_write", "audio_write":
            return [access("path")].compactMap { $0 }
        case "pdf_from_file":
            var accesses = [access("source_path")].compactMap { $0 }
            if let destination = access("dest_path") {
                accesses.append(destination)
            } else if let source = accesses.first {
                accesses.append(PathAccess(
                    key: "dest_path",
                    url: source.url.deletingPathExtension().appendingPathExtension("pdf"),
                    protectRoot: false,
                    preservesFinalComponent: false
                ))
            }
            return accesses
        case "git_status", "git_diff", "git_log":
            return [
                access("cwd") ?? PathAccess(
                    key: "cwd",
                    url: base,
                    protectRoot: false,
                    preservesFinalComponent: false
                ),
            ]
        case "git_add", "git_commit", "shell_exec", "process.run", "shell.run", "bash.run",
             "python.run", "powershell.run":
            return [
                access("cwd") ?? PathAccess(
                    key: "cwd",
                    url: base,
                    protectRoot: false,
                    preservesFinalComponent: false
                ),
            ]
        case "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator":
            // The typed Xcode boundary resolves its operands relative to cwd.
            return [access("cwd")].compactMap { $0 }
        default:
            return []
        }
    }

    private func defaultBase(
        binding: ActiveBinding?,
        context: ToolInvocationContext?,
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> URL {
        try cancellation?.checkCancellation()
        let candidates = [binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath)]
            + [context?.authorizationScope.canonicalRoots.first]
            + [try workspace?.additionalRoots(
                for: clientID,
                cancellation: cancellation
            ).first]
            + [config.model.allowedRoots.first.map(ToolArgHelpers.resolvePath)]
            + [paths.home]
        for candidate in candidates.compactMap({ $0 }) {
            return try canonicalURL(candidate, cancellation: cancellation)
        }
        return paths.home.standardizedFileURL
    }

    private func workspaceRoots(
        binding: ActiveBinding?,
        context: ToolInvocationContext?,
        clientID: ClientID,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        let candidates = [binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath)]
            + (context?.authorizationScope.canonicalRoots ?? [])
            + (try workspace?.additionalRoots(for: clientID, cancellation: cancellation) ?? [])
        var roots: [URL] = []
        for candidate in candidates.compactMap({ $0 }) {
            let canonical = try canonicalURL(candidate, cancellation: cancellation)
            if !roots.contains(canonical) { roots.append(canonical) }
        }
        return roots
    }

    private func destructiveRootProtections(
        workspaceRoots: [URL],
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        var candidates = workspaceRoots + [
            fileManager.homeDirectoryForCurrentUser,
            paths.home,
            URL(fileURLWithPath: "/", isDirectory: true),
        ]
        candidates.append(contentsOf: fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? [])
        var protected: [URL] = []
        for candidate in candidates {
            try cancellation?.checkCancellation()
            let canonical = try canonicalURL(candidate, cancellation: cancellation)
            if !protected.contains(canonical) { protected.append(canonical) }
        }
        return protected
    }

    /// Destructive source operands preserve their final path component so a
    /// symlink is removed or moved rather than its target. String comparison is
    /// insufficient on case-insensitive volumes because a differently-cased
    /// final component can still name the protected directory. Compare the
    /// existing leaf's lstat identity with every protected root and ancestor;
    /// lstat deliberately keeps a symlink leaf distinct from its destination.
    private func destructiveTargetIsProtected(
        _ candidate: URL,
        protectedRoots: [URL],
        cancellation: ToolCallCancellation?
    ) throws -> Bool {
        if candidate.path == "/"
            || protectedRoots.contains(where: {
                candidate == $0 || contains($0, root: candidate)
            }) {
            return true
        }
        guard let candidateIdentity = fileIdentity(at: candidate) else { return false }

        var inspectedAncestors = Set<URL>()
        for protectedRoot in protectedRoots {
            var ancestor = protectedRoot.standardizedFileURL
            while inspectedAncestors.insert(ancestor).inserted {
                try cancellation?.checkCancellation()
                if fileIdentity(at: ancestor) == candidateIdentity { return true }
                guard ancestor.path != "/" else { break }
                ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
            }
        }
        return false
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private func fileIdentity(at url: URL) -> FileIdentity? {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_dev >= 0,
              information.st_ino > 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func resolve(_ raw: String, relativeTo base: URL) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    private func configuredProjectRoots(
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        var roots: [URL] = []
        for raw in ManagerSettingsNormalizer.canonicalAllowedRoots(config.model.allowedRoots) {
            try cancellation?.checkCancellation()
            let root = try canonicalURL(
                ToolArgHelpers.resolvePath(raw),
                cancellation: cancellation
            )
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    /// Resolve symlinks in the deepest existing ancestor, then append any
    /// not-yet-created path suffix so execution and audit use one stable path.
    private func canonicalURL(
        _ url: URL,
        preservingFinalComponent: Bool = false,
        cancellation: ToolCallCancellation?
    ) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        if preservingFinalComponent, standardizedURL.path != "/" {
            let parent = try canonicalURL(
                standardizedURL.deletingLastPathComponent(),
                cancellation: cancellation
            )
            try cancellation?.checkCancellation()
            return parent
                .appendingPathComponent(standardizedURL.lastPathComponent)
                .standardizedFileURL
        }
        var existing = standardizedURL
        var suffix: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            try cancellation?.checkCancellation()
            suffix.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        try cancellation?.checkCancellation()
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix.reversed() {
            try cancellation?.checkCancellation()
            resolved.appendPathComponent(component)
        }
        try cancellation?.checkCancellation()
        return resolved.standardizedFileURL
    }

    private func contains(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static let sessionLifecycleTools: Set<String> = [
        "forge_status", "get_forge_status",
        "agent_list", "agent_get", "agent_context", "agent_recommend",
        "agent_run_start", "agent_run_status", "agent_run_complete",
        // Durable memory remains available without and during agent sessions.
        "memory_set", "memory_get", "memory_list", "memory_delete", "memory_search",
        "project_memory.initialize", "project_memory.remember", "project_memory.remember_batch",
        "project_memory.search", "project_memory.get", "project_memory.update",
        "project_memory.forget", "project_memory.list_recent", "project_memory.link",
        "project_memory.export", "project_memory.import", "project_memory.status",
        "session_checkpoint", "session_handoff", "context_get", "context_list",
        "continuity.checkpoint", "continuity.prepare_handoff",
        "continuity.get_pending_handoff", "continuity.acknowledge_handoff",
        "continuity.resume", "continuity.status", "continuity.request_rollover",
    ]

    private static let requiresActiveSession: Set<String> = [
        "shell_exec", "git_add", "git_commit",
    ]

    private static let projectRegistrationTools: Set<String> = [
        "agent_run_start", "project_memory.initialize",
    ]

    private static let cwdTools: Set<String> = [
        "git_status", "git_diff", "git_log", "git_add", "git_commit", "shell_exec",
        "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
        "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator",
    ]

    static let runtimeExecutionTools: Set<String> = [
        "shell_exec", "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
        "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator",
    ]

}

public enum ToolAuditSanitizer {
    private static let maximumDepth = 8
    private static let maximumCollectionItems = 128
    private static let maximumStringBytes = 4 * 1_024
    private static let sensitiveKeys: Set<String> = [
        "command", "content", "old", "new", "report", "goal", "body", "value",
        "rows", "slides",
        "narrative", "summary", "resume_seed", "blockers", "next_actions",
        "decisions", "key_files", "cwd", "project_slug", "project", "chat_label", "chat", "status",
    ]

    public static func sanitize(_ arguments: [String: Any]) -> [String: Any] {
        sanitizeDictionary(arguments, depth: 0)
    }

    private static func sanitizeDictionary(
        _ dictionary: [String: Any],
        depth: Int
    ) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for key in dictionary.keys.sorted().prefix(maximumCollectionItems) {
            guard let value = dictionary[key] else { continue }
            if sensitiveKeys.contains(key.lowercased()) {
                if let string = value as? String {
                    sanitized[key] = "<redacted:\(string.utf8.count) bytes>"
                } else {
                    sanitized[key] = "<redacted>"
                }
            } else {
                sanitized[key] = sanitizeValue(value, depth: depth + 1)
            }
        }
        if dictionary.count > maximumCollectionItems {
            sanitized["_truncated_fields"] = dictionary.count - maximumCollectionItems
        }
        return sanitized
    }

    private static func sanitizeValue(_ value: Any, depth: Int) -> Any {
        guard depth <= maximumDepth else { return "<truncated:maximum-depth>" }
        if let dictionary = value as? [String: Any] {
            return sanitizeDictionary(dictionary, depth: depth)
        }
        if let values = value as? [Any] {
            var sanitized = values.prefix(maximumCollectionItems).map {
                sanitizeValue($0, depth: depth + 1)
            }
            if values.count > maximumCollectionItems {
                sanitized.append("<truncated:\(values.count - maximumCollectionItems) items>")
            }
            return sanitized
        }
        if let string = value as? String, string.utf8.count > maximumStringBytes {
            return "<truncated:\(string.utf8.count) bytes>"
        }
        return value
    }
}

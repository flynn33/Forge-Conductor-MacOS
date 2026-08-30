// ToolAuthorizationService.swift
// What: Enforces agent grants, denials, and filesystem workspace boundaries.
// How: It canonicalizes requested paths before dispatch, evaluates the active agent's
// policy, blocks symlink escapes, and sanitizes arguments before audit persistence.
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
/// Agent tool grants and workspace roots are enforced here so a new tool pack
/// cannot accidentally bypass policy by forgetting a local check.
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

        let readRoots = try authorizedRoots(
            binding: binding,
            context: context,
            clientID: clientID,
            excludeFilesystemRoot: tool == "project_memory.initialize",
            cancellation: cancellation
        )
        let writeRoots = try authorizedWriteRoots(
            readRoots: readRoots,
            context: context,
            cancellation: cancellation
        )
        let base = binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath)
            ?? readRoots.first
            ?? paths.home
        var normalized = arguments

        for access in pathAccesses(tool: tool, arguments: arguments, base: base) {
            try cancellation?.checkCancellation()
            guard access.url.path.utf8.count <= Int(PATH_MAX) else {
                return .denied(
                    code: "invalid_path",
                    message: "Path exceeds the supported filesystem limit"
                )
            }
            let candidate = try canonicalURL(access.url, cancellation: cancellation)
            if tool == "project_memory.initialize", candidate.path == "/" {
                return .denied(
                    code: "project_bootstrap_root_forbidden",
                    message: "The filesystem root cannot become a project authorization root"
                )
            }
            let containingReadRoot = readRoots.first(where: { contains(candidate, root: $0) })
            guard containingReadRoot != nil else {
                return .denied(
                    code: "path_outside_allowed_roots",
                    message: "Path is outside the active workspace roots: \(candidate.path)"
                )
            }
            let containingRoot: URL?
            if access.requiresWrite {
                containingRoot = writeRoots.first(where: { contains(candidate, root: $0) })
            } else {
                containingRoot = containingReadRoot
            }
            if containingRoot == nil, access.requiresWrite {
                return .denied(
                    code: "path_outside_writable_roots",
                    message: "Path is outside the active writable workspace roots: \(candidate.path)"
                )
            }
            if access.protectRoot, let containingRoot, candidate == containingRoot {
                return .denied(
                    code: "workspace_root_protected",
                    message: "The workspace root itself cannot be deleted or moved: \(candidate.path)"
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
        var requiresWrite: Bool
    }

    private func pathAccesses(
        tool: String,
        arguments: [String: Any],
        base: URL
    ) -> [PathAccess] {
        func access(
            _ key: String,
            protectRoot: Bool = false,
            requiresWrite: Bool = false
        ) -> PathAccess? {
            guard let raw = ToolArgHelpers.string(arguments, key), !raw.isEmpty else { return nil }
            return PathAccess(
                key: key,
                url: resolve(raw, relativeTo: base),
                protectRoot: protectRoot,
                requiresWrite: requiresWrite
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
                projectPathKey.flatMap { access($0, requiresWrite: true) },
            ].compactMap { $0 }
        case "fs_read":
            return [access("path")].compactMap { $0 }
        case "fs_write", "fs_edit", "fs_mkdir":
            return [access("path", requiresWrite: true)].compactMap { $0 }
        case "fs_list", "fs_glob", "search_text":
            return [
                access("path") ?? PathAccess(
                    key: "path",
                    url: base,
                    protectRoot: false,
                    requiresWrite: false
                ),
            ]
        case "fs_delete":
            return [access("path", protectRoot: true, requiresWrite: true)].compactMap { $0 }
        case "fs_move":
            let sourceKey = ["path", "src", "source"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            let destinationKey = ["dest", "destination"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            return [
                sourceKey.flatMap { access($0, protectRoot: true, requiresWrite: true) },
                destinationKey.flatMap { access($0, requiresWrite: true) },
            ].compactMap { $0 }
        case "pdf_write":
            return [access("path", requiresWrite: true)].compactMap { $0 }
        case "pdf_from_file":
            var accesses = [access("source_path")].compactMap { $0 }
            if let destination = access("dest_path", requiresWrite: true) {
                accesses.append(destination)
            } else if let source = accesses.first {
                accesses.append(PathAccess(
                    key: "dest_path",
                    url: source.url.deletingPathExtension().appendingPathExtension("pdf"),
                    protectRoot: false,
                    requiresWrite: true
                ))
            }
            return accesses
        case "git_status", "git_diff", "git_log":
            return [
                access("cwd") ?? PathAccess(
                    key: "cwd",
                    url: base,
                    protectRoot: false,
                    requiresWrite: false
                ),
            ]
        case "git_add", "git_commit", "shell_exec", "process.run", "shell.run", "bash.run",
             "python.run", "powershell.run":
            return [
                access("cwd", requiresWrite: true) ?? PathAccess(
                    key: "cwd",
                    url: base,
                    protectRoot: false,
                    requiresWrite: true
                ),
            ]
        default:
            return []
        }
    }

    private func authorizedRoots(
        binding: ActiveBinding?,
        context: ToolInvocationContext?,
        clientID: ClientID,
        excludeFilesystemRoot: Bool = false,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        try cancellation?.checkCancellation()
        if let context {
            let contextualRoots = try canonicalizedUnique(
                context.authorizationScope.canonicalRoots,
                cancellation: cancellation
            )
            return excludeFilesystemRoot
                ? contextualRoots.filter { $0.path != "/" }
                : contextualRoots
        }
        var trusted = try canonicalizedUnique(
            config.model.allowedRoots.map(ToolArgHelpers.resolvePath),
            cancellation: cancellation
        )
        if excludeFilesystemRoot {
            trusted.removeAll { $0.path == "/" }
        }
        let claimed = [binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath)].compactMap { $0 }
            + (try workspace?.additionalRoots(for: clientID, cancellation: cancellation) ?? [])
        guard !claimed.isEmpty else { return trusted }
        var canonicalClaims: [URL] = []
        canonicalClaims.reserveCapacity(claimed.count)
        for claim in claimed {
            try cancellation?.checkCancellation()
            canonicalClaims.append(try canonicalURL(claim, cancellation: cancellation))
        }
        return canonicalClaims.filter { candidate in
            trusted.contains { contains(candidate, root: $0) }
        }.reduce(into: [URL]()) { roots, root in
            if !roots.contains(root) { roots.append(root) }
        }
    }

    private func authorizedWriteRoots(
        readRoots: [URL],
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        guard let context else { return readRoots }
        let requested = try canonicalizedUnique(
            context.authorizationScope.writableRoots,
            cancellation: cancellation
        )
        return requested.filter { candidate in
            readRoots.contains { contains(candidate, root: $0) }
        }
    }

    private func resolve(_ raw: String, relativeTo base: URL) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Resolve symlinks in the deepest existing ancestor, then append any
    /// not-yet-created path suffix. This prevents writes through a symlink that
    /// points outside an allowed root.
    private func canonicalizedUnique(
        _ urls: [URL],
        cancellation: ToolCallCancellation?
    ) throws -> [URL] {
        var roots: [URL] = []
        roots.reserveCapacity(urls.count)
        for url in urls {
            try cancellation?.checkCancellation()
            let root = try canonicalURL(url, cancellation: cancellation)
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    private func canonicalURL(
        _ url: URL,
        cancellation: ToolCallCancellation?
    ) throws -> URL {
        var existing = url.standardizedFileURL
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
        "forge_status", "agent_list", "agent_get", "agent_context", "agent_recommend",
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

    private static let cwdTools: Set<String> = [
        "git_status", "git_diff", "git_log", "git_add", "git_commit", "shell_exec",
        "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
    ]

    private static let runtimeExecutionTools: Set<String> = [
        "shell_exec", "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
    ]

}

public enum ToolAuditSanitizer {
    private static let maximumDepth = 8
    private static let maximumCollectionItems = 128
    private static let maximumStringBytes = 4 * 1_024
    private static let sensitiveKeys: Set<String> = [
        "command", "content", "old", "new", "report", "goal", "body", "value",
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

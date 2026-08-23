// ToolAuthorizationService.swift
// What: Enforces agent grants, denials, and filesystem workspace boundaries.
// How: It canonicalizes requested paths before dispatch, evaluates the active agent's
// policy, blocks symlink escapes, and sanitizes arguments before audit persistence.
// Why: Authorization must be centralized so no connector can bypass safety rules.

import Foundation

/// Captures the complete result of evaluating one tool invocation against policy.
///
/// Allowed calls carry normalized arguments forward to execution; denied calls carry
/// a stable machine code and a user-facing explanation back to the transport adapter.
public enum ToolAuthorizationDecision {
    case allowed(arguments: [String: Any])
    case denied(code: String, message: String)
}

/// Defines the authorization boundary that every tool call must cross before routing.
public protocol ToolAuthorizing: Sendable {
    func authorize(
        tool: String,
        arguments: [String: Any],
        clientID: ClientID,
        binding: ActiveBinding?
    ) -> ToolAuthorizationDecision
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
        if let binding {
            if binding.toolsForbidden.contains(tool) {
                return .denied(
                    code: "tool_forbidden",
                    message: "Agent '\(binding.agentID)' explicitly forbids tool '\(tool)'"
                )
            }
            if !binding.toolsPrimary.isEmpty,
               !binding.toolsPrimary.contains(tool),
               !Self.sessionLifecycleTools.contains(tool) {
                return .denied(
                    code: "tool_not_granted",
                    message: "Tool '\(tool)' is not granted to agent '\(binding.agentID)'"
                )
            }
        } else if Self.requiresActiveSession.contains(tool) {
            let extras = workspace?.additionalRoots(for: clientID) ?? []
            if extras.isEmpty {
                return .denied(
                    code: "active_session_required",
                    message: "Tool '\(tool)' requires agent_run_start with an explicit workspace cwd"
                )
            }
        }

        let roots = authorizedRoots(binding: binding, clientID: clientID)
        let base = binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath) ?? roots.first ?? paths.home
        var normalized = arguments

        let readOnly = Self.readOnlyPathTools.contains(tool)
        for access in pathAccesses(tool: tool, arguments: arguments, base: base) {
            let candidate = canonicalURL(access.url)
            var containingRoot = roots.first(where: { contains(candidate, root: $0) })
            if containingRoot == nil, readOnly, isPermittedHomeRead(candidate) {
                containingRoot = homeReadRoot(for: candidate)
            }
            guard let containingRoot else {
                return .denied(
                    code: "path_outside_allowed_roots",
                    message: "Path is outside the active workspace roots: \(candidate.path)"
                )
            }
            if access.protectRoot && candidate == containingRoot {
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
        return .allowed(arguments: normalized)
    }

    private struct PathAccess {
        var key: String
        var url: URL
        var protectRoot: Bool
    }

    private func pathAccesses(
        tool: String,
        arguments: [String: Any],
        base: URL
    ) -> [PathAccess] {
        func access(_ key: String, protectRoot: Bool = false) -> PathAccess? {
            guard let raw = ToolArgHelpers.string(arguments, key), !raw.isEmpty else { return nil }
            return PathAccess(key: key, url: resolve(raw, relativeTo: base), protectRoot: protectRoot)
        }

        switch tool {
        case "fs_read", "fs_write", "fs_edit", "fs_mkdir":
            return [access("path")].compactMap { $0 }
        case "fs_list", "fs_glob", "search_text":
            return [access("path") ?? PathAccess(key: "path", url: base, protectRoot: false)]
        case "fs_delete":
            return [access("path", protectRoot: true)].compactMap { $0 }
        case "fs_move":
            let sourceKey = ["path", "src", "source"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            let destinationKey = ["dest", "destination"].first {
                ToolArgHelpers.string(arguments, $0) != nil
            }
            return [
                sourceKey.flatMap { access($0, protectRoot: true) },
                destinationKey.flatMap { access($0) },
            ].compactMap { $0 }
        case "pdf_write":
            return [access("path")].compactMap { $0 }
        case "pdf_from_file":
            var accesses = [access("source_path")].compactMap { $0 }
            if let destination = access("dest_path") {
                accesses.append(destination)
            } else if let source = accesses.first {
                accesses.append(PathAccess(
                    key: "dest_path",
                    url: source.url.deletingPathExtension().appendingPathExtension("pdf"),
                    protectRoot: false
                ))
            }
            return accesses
        case "git_status", "git_diff", "git_log", "git_add", "git_commit", "shell_exec":
            return [
                access("cwd") ?? PathAccess(key: "cwd", url: base, protectRoot: false),
            ]
        default:
            return []
        }
    }

    private func authorizedRoots(binding: ActiveBinding?, clientID: ClientID) -> [URL] {
        let configured = config.model.allowedRoots.map(ToolArgHelpers.resolvePath)
        let bindingRoot = binding.flatMap(\.cwd).map(ToolArgHelpers.resolvePath)
        let extra = workspace?.additionalRoots(for: clientID) ?? []
        return ([paths.home] + configured + [bindingRoot].compactMap { $0 } + extra)
            .map(canonicalURL)
            .reduce(into: [URL]()) { roots, root in
                if !roots.contains(root) { roots.append(root) }
            }
    }

    /// Read-only access under the interactive user's home, excluding secret/system trees.
    private func isPermittedHomeRead(_ url: URL) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard contains(url, root: home) else { return false }
        let relative = url.pathComponents.dropFirst(home.pathComponents.count).map { $0.lowercased() }
        guard let first = relative.first else { return false }
        return !Self.deniedHomePrefixes.contains(first)
    }

    private func homeReadRoot(for url: URL) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let extras = url.pathComponents.dropFirst(home.pathComponents.count)
        if let first = extras.first {
            return home.appendingPathComponent(first).standardizedFileURL
        }
        return home
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
    private func canonicalURL(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix {
            resolved.appendPathComponent(component)
        }
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
    ]

    private static let readOnlyPathTools: Set<String> = [
        "fs_read", "fs_list", "fs_glob", "search_text",
    ]

    private static let deniedHomePrefixes: Set<String> = [
        "library", ".ssh", ".gnupg", ".aws", ".config", ".trash",
        "applications",
    ]
}

public enum ToolAuditSanitizer {
    private static let sensitiveKeys: Set<String> = [
        "command", "content", "old", "new", "report", "goal", "body", "value",
        "narrative", "summary", "resume_seed", "blockers", "next_actions",
        "decisions", "key_files", "cwd", "project_slug", "project", "chat_label", "chat", "status",
    ]

    public static func sanitize(_ arguments: [String: Any]) -> [String: Any] {
        arguments.reduce(into: [String: Any]()) { sanitized, pair in
            guard sensitiveKeys.contains(pair.key) else {
                sanitized[pair.key] = pair.value
                return
            }
            if let string = pair.value as? String {
                sanitized[pair.key] = "<redacted:\(string.utf8.count) bytes>"
            } else {
                sanitized[pair.key] = "<redacted>"
            }
        }
    }
}

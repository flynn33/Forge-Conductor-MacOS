import Foundation
import Darwin

/// Produces native-target evidence on the policy emitter's serial worker.
/// Authority comes from the current project generation and its Xcode graph,
/// rather than tool success, source extensions outside targets, or model claims.
public actor StjornarvaldNativeTargetObservationProducer {
    private let projects: ProjectControlPlaneRepository
    private var previousDigests: [String: String] = [:]
    private var digestOrder: [String] = []

    public init(projectContexts: ProjectContextService) {
        projects = projectContexts.repository
    }

    func observation(after tool: DevelopmentObservation) async -> DevelopmentObservation? {
        guard tool.kind == .toolInvocationCompleted,
              let rawID = tool.scope.projectID, let uuid = UUID(uuidString: rawID),
              let generation = tool.scope.projectGeneration,
              Self.observedTools.contains(tool.subjectIdentity),
              let project = try? await projects.project(ProjectID(uuid)),
              project.lifecycleState == .active,
              Int(exactly: project.generation.rawValue) == generation,
              await managedScopeIsCurrent(tool.scope) else { return nil }
        let capture = StjornarvaldNativeTargetMembership.capture(root: project.canonicalRoot)
        guard capture.projectCount > 0 || !capture.limitations.isEmpty else { return nil }
        // Recheck after traversal: a reset/relink/archive cannot label an old
        // source graph as evidence for the new active generation.
        guard let current = try? await projects.project(project.projectID),
              current.lifecycleState == .active, current.generation == project.generation,
              current.canonicalRoot == project.canonicalRoot,
              await managedScopeIsCurrent(tool.scope) else { return nil }
        let identity = Self.captureIdentity(tool.scope)
        guard previousDigests[identity] != capture.digest else { return nil }
        let key = "native-target:\(tool.id.uuidString.lowercased()):\(capture.digest)"
        let complete = capture.limitations.isEmpty
        let summary = complete
            ? "Declared Xcode production source/resource/copy membership captured; test targets and build-script phases excluded."
            : "Declared Xcode production source/resource/copy membership is incomplete: " + capture.limitations.prefix(4).joined(separator: "; ")
        let observation = DevelopmentObservation(
            id: StjornarvaldProductObservationFactory.deterministicUUID(key),
            idempotencyKey: key, kind: .projectConfigurationObserved,
            observedAt: tool.observedAt, scope: tool.scope,
            subjectIdentity: "project:\(rawID):native-production-targets",
            summary: StjornarvaldPolicyNoticeFormatter.bounded(summary, bytes: 4_096),
            evidenceReferences: ["xcode_membership_sha256:\(capture.digest)"],
            payloadSHA256: capture.digest,
            // Unsupported graphs remain explicit activity, rather than an
            // invented native-stack pass or a policy violation from a tool error.
            details: complete ? DevelopmentObservationDetails(nativeTarget:
                NativeTargetObservationEvidence(shippingRuntimePaths: capture.paths,
                                                targetMembershipComplete: true,
                                                declaredPathRoles: capture.declaredPathRoles)) : nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(observation),
           data.count <= StjornarvaldObservationRepository.maximumObservationBytes { return observation }
        return DevelopmentObservation(id: observation.id, idempotencyKey: observation.idempotencyKey,
            kind: observation.kind, observedAt: observation.observedAt, scope: observation.scope,
            subjectIdentity: observation.subjectIdentity,
            summary: "Declared Xcode membership is incomplete: observation could not be encoded within its transport budget.",
            evidenceReferences: observation.evidenceReferences, payloadSHA256: observation.payloadSHA256)
    }

    // A void-only submitter cannot confirm durable acceptance. Its next call
    // must retry the graph rather than cache evidence that may have been lost.
    func confirmRetention(of observation: DevelopmentObservation) {
        guard observation.kind == .projectConfigurationObserved,
              observation.scope.projectID != nil,
              observation.scope.projectGeneration != nil else { return }
        let identity = Self.captureIdentity(observation.scope)
        if previousDigests[identity] == nil { digestOrder.append(identity) }
        previousDigests[identity] = observation.payloadSHA256
        if digestOrder.count > 64 { previousDigests.removeValue(forKey: digestOrder.removeFirst()) }
    }

    private func managedScopeIsCurrent(_ scope: DevelopmentObservationScope) async -> Bool {
        guard let runID = scope.runID else { return true }
        guard UUID(uuidString: runID) != nil,
              let sessionID = scope.sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 1_024,
              let context = try? await projects.invocationContext(
                  for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
                  cancellation: ToolCallCancellation(timeoutSeconds: 5)
              ),
              context.runID?.description == runID,
              context.providerSessionID == sessionID,
              context.projectID.description == scope.projectID,
              Int(exactly: context.projectGeneration.rawValue) == scope.projectGeneration else { return false }
        return true
    }

    private static func captureIdentity(_ scope: DevelopmentObservationScope) -> String {
        var components = [scope.projectID ?? "", String(scope.projectGeneration ?? -1), scope.clientID ?? ""]
        if let runID = scope.runID {
            components.append(runID)
            components.append(scope.sessionID ?? "")
        }
        return components.joined(separator: "\u{0}")
    }

    private static let observedTools: Set<String> = Set([
        "get_forge_status", "project_memory.initialize", "fs_write", "fs_edit", "fs_move", "fs_delete",
        "shell_exec", "process.run", "shell.run", "bash.run", "python.run", "powershell.run",
        "job.status", "job.list", "job.read_output",
    ].map { "tool:" + $0 } + XcodeCLIToolPack.names.map { "tool:" + $0 })
}

struct StjornarvaldNativeTargetMembership {
    static let maximumProjectBytes = 4 * 1_024 * 1_024
    static let maximumObjects = 20_000
    static let maximumEntries = 10_000
    static let maximumProjects = 8
    static let maximumPathPayloadBytes = 128 * 1_024
    static let maximumMembershipPayloadBytes = 192 * 1_024
    let projectCount: Int
    let paths: [String]
    let declaredPathRoles: [String: [NativeTargetDeclaredRole]]
    let limitations: [String]
    let digest: String

    static func capture(root: URL) -> Self {
        capture(root: root, clock: SystemClock())
    }

    static func capture(root: URL, clock: any Clock) -> Self {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let reader = MembershipReader(root: root, clock: clock)
        reader.read()
        let paths = reader.paths.sorted()
        let roles = reader.declaredPathRoles.mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
        let roleIdentity = paths.map { path in
            ([path] + (roles[path] ?? []).map(\.rawValue)).joined(separator: "\u{0}")
        }
        let limitations = reader.limitations.sorted()
        let digest = JSONSupport.sha256Hex((reader.graphDigests.sorted() + paths + roleIdentity + limitations)
            .joined(separator: "\u{0}"))
        return Self(projectCount: reader.projectCount, paths: paths, declaredPathRoles: roles,
                    limitations: limitations, digest: digest)
    }
}

private final class MembershipReader {
    let root: URL
    let clock: any Clock
    let deadline: Date
    var paths: Set<String> = []
    var declaredPathRoles: [String: Set<NativeTargetDeclaredRole>] = [:]
    var rolePayloadBytes = 0
    var limitations: Set<String> = []
    var graphDigests: [String] = []
    var projectCount = 0
    var entryCount = 0
    var pathPayloadBytes = 0
    var seenProjects: Set<String> = []
    var traversalVisits = 0
    init(root: URL, clock: any Clock) {
        self.root = root
        self.clock = clock
        deadline = clock.now().addingTimeInterval(2)
    }

    func hasRemainingTraversalBudget() -> Bool {
        guard traversalVisits < StjornarvaldNativeTargetMembership.maximumEntries else {
            limitations.insert("membership traversal exceeded its bound"); return false
        }
        return withinCaptureDeadline()
    }

    func withinCaptureDeadline() -> Bool {
        guard clock.now() < deadline else {
            limitations.insert("membership traversal exceeded its deadline"); return false
        }
        return true
    }

    func admitTraversalVisit() -> Bool {
        guard hasRemainingTraversalBudget() else { return false }
        // Count visits before deduplication, including aliases and unsupported references.
        traversalVisits += 1
        return true
    }

    func read() {
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            limitations.insert("project root is unavailable"); return
        }
        var rootCount = 0
        for case let entry as URL in entries {
            entries.skipDescendants()
            rootCount += 1
            guard rootCount <= 256 else {
                limitations.insert("project discovery exceeded its bound"); break
            }
            guard admitTraversalVisit() else { break }
            if entry.pathExtension == "xcodeproj" {
                includeProject(entry)
            }
            if entry.pathExtension == "xcworkspace" {
                readWorkspace(entry)
            }
        }
    }

    func includeProject(_ url: URL) {
        guard admitTraversalVisit() else { return }
        guard contained(url), url.pathExtension == "xcodeproj",
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            limitations.insert("workspace project reference is external or unsupported"); return
        }
        guard seenProjects.insert(url.standardizedFileURL.path).inserted else { return }
        guard projectCount < StjornarvaldNativeTargetMembership.maximumProjects else {
            limitations.insert("project count exceeded its bound"); return
        }
        projectCount += 1
        readProject(url)
    }

    func readWorkspace(_ url: URL) {
        guard contained(url),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            limitations.insert("workspace reference is external or a symbolic link"); return
        }
        do {
            let file = url.appendingPathComponent("contents.xcworkspacedata")
            let data = try boundedRead(file, maximum: 256 * 1_024)
            let delegate = WorkspaceMembershipReferences()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), !delegate.unsupported else {
                limitations.insert("workspace reference format is unsupported"); return
            }
            graphDigests.append(JSONSupport.sha256Hex(data))
            for path in delegate.paths {
                guard hasRemainingTraversalBudget() else { break }
                includeProject(url.deletingLastPathComponent().appendingPathComponent(path))
            }
            if try boundedRead(file, maximum: 256 * 1_024) != data {
                limitations.insert("workspace changed during capture")
            }
        } catch { limitations.insert("workspace could not be read within its bound") }
    }

    func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MembershipReadError.unsupportedFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw MembershipReadError.unsupportedFile }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw MembershipReadError.byteBound }
        return data
    }

    func readProject(_ projectURL: URL) {
        let file = projectURL.appendingPathComponent("project.pbxproj")
        do {
            let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard metadata.isSymbolicLink != true else {
                limitations.insert("project file is a symbolic link"); return
            }
            guard metadata.isRegularFile == true else {
                limitations.insert("project file is not a regular file"); return
            }
            guard (metadata.fileSize ?? Int.max) <= StjornarvaldNativeTargetMembership.maximumProjectBytes else {
                limitations.insert("project file exceeded its bound"); return
            }
            let data = try boundedRead(file, maximum: StjornarvaldNativeTargetMembership.maximumProjectBytes)
            guard data.count <= StjornarvaldNativeTargetMembership.maximumProjectBytes,
                  let graph = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let objects = graph["objects"] as? [String: [String: Any]],
                  objects.count <= StjornarvaldNativeTargetMembership.maximumObjects,
                  let rootID = graph["rootObject"] as? String,
                  objects[rootID]?["isa"] as? String == "PBXProject",
                  let mainGroup = objects[rootID]?["mainGroup"] as? String,
                  let mainGroupKind = objects[mainGroup]?["isa"] as? String,
                  Self.childGroupTypes.contains(mainGroupKind) || mainGroupKind == "PBXFileSystemSynchronizedRootGroup",
                  let targetIDs = objects[rootID]?["targets"] as? [String] else {
                limitations.insert("project graph is unsupported or exceeds its bound"); return
            }
            graphDigests.append(JSONSupport.sha256Hex(data))
            var references: [String: URL] = [:]
            var visited: Set<String> = []
            func resolve(_ id: String, parent: URL, depth: Int = 0) {
                guard depth <= 64 else {
                    limitations.insert("group traversal exceeded its depth or deadline"); return
                }
                guard admitTraversalVisit() else { return }
                guard visited.insert(id).inserted else { return }
                guard let object = objects[id], let role = object["isa"] as? String else {
                    limitations.insert("declared group or file reference is missing"); return
                }
                if let rawPath = object["path"], !(rawPath is String) {
                    limitations.insert("declared reference path is malformed"); return
                }
                if let rawTree = object["sourceTree"], !(rawTree is String) {
                    limitations.insert("declared reference source tree is malformed"); return
                }
                let children: [String]
                if let rawChildren = object["children"] {
                    guard let values = rawChildren as? [String] else {
                        limitations.insert("declared group children are malformed"); return
                    }
                    children = values
                } else if Self.childGroupTypes.contains(role) {
                    limitations.insert("declared group children are missing"); return
                } else { children = [] }
                let tree = object["sourceTree"] as? String ?? "<group>"
                let path = object["path"] as? String ?? ""
                let base = tree == "SOURCE_ROOT" ? projectURL.deletingLastPathComponent() : parent
                if tree == "SOURCE_ROOT" || tree == "<group>" {
                    let url = path.isEmpty ? base : base.appendingPathComponent(path).standardizedFileURL
                    references[id] = url
                    for child in children {
                        guard hasRemainingTraversalBudget() else { break }
                        resolve(child, parent: url, depth: depth + 1)
                    }
                }
            }
            resolve(mainGroup, parent: projectURL.deletingLastPathComponent())
            var targets: [String: [String: Any]] = [:]
            for id in targetIDs {
                guard admitTraversalVisit() else { break }
                guard let target = objects[id], let role = target["isa"] as? String else {
                    limitations.insert("declared target is missing"); continue
                }
                // Aggregate targets contain build automation, not declared runtime files.
                if role == "PBXAggregateTarget" { continue }
                guard role == "PBXNativeTarget", let product = target["productType"] as? String else {
                    limitations.insert("declared target kind or product type is unsupported"); continue
                }
                if product == "com.apple.product-type.bundle.unit-test"
                    || product == "com.apple.product-type.bundle.ui-testing" { continue }
                guard Self.productionTypes.contains(product) else {
                    limitations.insert("target product type is unsupported"); continue
                }
                targets[id] = target
            }
            // Only root-declared production products have membership captured below.
            // An embedded excluded test product or an orphan product is unresolved evidence.
            let orderedTargets = hasRemainingTraversalBudget()
                ? targets.sorted { $0.key < $1.key } : []
            var productReferences: Set<String> = []
            for (_, target) in orderedTargets {
                guard admitTraversalVisit() else { break }
                if let reference = target["productReference"] as? String { productReferences.insert(reference) }
            }
            productionMembership: for (targetID, target) in orderedTargets {
                guard admitTraversalVisit() else { break }
                guard let phaseIDs = target["buildPhases"] as? [String] else {
                    limitations.insert("production target build phases are missing or malformed"); continue
                }
                let synchronizedGroupIDs: [String]
                if let rawGroups = target["fileSystemSynchronizedGroups"] {
                    guard let groups = rawGroups as? [String] else {
                        limitations.insert("production synchronized groups are malformed"); continue
                    }
                    synchronizedGroupIDs = groups
                } else { synchronizedGroupIDs = [] }
                for phaseID in phaseIDs {
                    guard admitTraversalVisit() else { break productionMembership }
                    guard let phase = objects[phaseID], let role = phase["isa"] as? String else {
                        limitations.insert("build phase is missing"); continue
                    }
                    // Build/test automation executes during the build, not in the application.
                    if role == "PBXShellScriptBuildPhase" || role == "PBXFrameworksBuildPhase"
                        || role == "PBXHeadersBuildPhase" { continue }
                    guard ["PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXCopyFilesBuildPhase"].contains(role) else {
                        limitations.insert("build phase is unsupported"); continue
                    }
                    guard let buildIDs = phase["files"] as? [String] else {
                        limitations.insert("production phase files are missing or malformed"); continue
                    }
                    for buildID in buildIDs {
                        guard admitTraversalVisit() else { break productionMembership }
                        guard let reference = objects[buildID]?["fileRef"] as? String else {
                            limitations.insert("build-file reference is missing"); continue
                        }
                        if let url = references[reference] {
                            let declaredRole: NativeTargetDeclaredRole = switch role {
                            case "PBXSourcesBuildPhase": .source
                            case "PBXResourcesBuildPhase": .resource
                            default: .copy
                            }
                            add(url, exclusions: [], synchronized: false, role: declaredRole)
                        }
                        else if !productReferences.contains(reference) {
                            limitations.insert("production file reference is unresolved")
                        }
                    }
                }
                for groupID in synchronizedGroupIDs {
                    guard admitTraversalVisit() else { break productionMembership }
                    guard let group = objects[groupID], let url = references[groupID],
                          group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" else {
                        limitations.insert("synchronized group is unresolved"); continue
                    }
                    var exclusions: Set<String> = []
                    var supported = (group["explicitFileTypes"] == nil || (group["explicitFileTypes"] as? [String: String])?.isEmpty == true)
                        && (group["explicitFolders"] == nil || (group["explicitFolders"] as? [String])?.isEmpty == true)
                    let exceptionIDs: [String]
                    if let rawExceptions = group["exceptions"] {
                        guard let values = rawExceptions as? [String] else {
                            limitations.insert("synchronized-group exception semantics are unsupported"); continue
                        }
                        exceptionIDs = values
                    } else { exceptionIDs = [] }
                    for exceptionID in exceptionIDs {
                        guard admitTraversalVisit() else { break productionMembership }
                        guard let exception = objects[exceptionID],
                              exception["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet",
                              exception["target"] as? String != nil else {
                            supported = false; continue
                        }
                        if exception["target"] as? String == targetID {
                            guard let members = exception["membershipExceptions"] as? [String] else {
                                supported = false; continue
                            }
                            for member in members {
                                guard admitTraversalVisit() else { break productionMembership }
                                if member.hasPrefix("/") || member.split(separator: "/").contains("..") {
                                    supported = false
                                } else { exclusions.insert(member) }
                            }
                            let known: Set<String> = ["isa", "target", "membershipExceptions"]
                            if !Set(exception.keys).isSubset(of: known) { supported = false }
                        }
                    }
                    if supported { add(url, exclusions: exclusions, synchronized: true, role: .synchronized) }
                    else { limitations.insert("synchronized-group exception semantics are unsupported") }
                }
            }
            if targets.isEmpty, hasRemainingTraversalBudget() {
                limitations.insert("no supported production target is declared")
            }
            if clock.now() >= deadline { limitations.insert("membership traversal exceeded its deadline") }
            // Detect a changing graph rather than labeling a mixed read complete.
            if try boundedRead(file, maximum: StjornarvaldNativeTargetMembership.maximumProjectBytes) != data {
                limitations.insert("project graph changed during capture")
            }
        } catch { limitations.insert("project graph could not be read") }
    }

    func add(_ url: URL, exclusions: Set<String>, synchronized: Bool, role: NativeTargetDeclaredRole) {
        guard withinCaptureDeadline() else { return }
        guard contained(url) else {
            limitations.insert("membership path is outside the project or capture deadline"); return
        }
        do {
            let metadata = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true else {
                limitations.insert("symbolic-link membership is unsupported"); return
            }
            if metadata.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey], options: []) else {
                    limitations.insert("production directory is unavailable"); return
                }
                for case let child as URL in enumerator {
                    guard admitTraversalVisit() else { break }
                    entryCount += 1
                    guard entryCount <= StjornarvaldNativeTargetMembership.maximumEntries else {
                        limitations.insert("membership traversal exceeded its bound"); break
                    }
                    guard withinCaptureDeadline() else { break }
                    guard let relative = relativePath(child, from: url) else {
                        enumerator.skipDescendants()
                        limitations.insert("membership path is outside the declared directory"); continue
                    }
                    if exclusions.contains(relative) { enumerator.skipDescendants(); continue }
                    let info = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
                    if synchronized && (info.isHidden == true || child.lastPathComponent.hasPrefix(".")) {
                        enumerator.skipDescendants()
                        limitations.insert("synchronized hidden-entry membership semantics are unsupported")
                        continue
                    }
                    if info.isSymbolicLink == true {
                        enumerator.skipDescendants(); limitations.insert("symbolic-link membership is unsupported"); continue
                    }
                    if info.isDirectory != true { addFile(child, role: role, countEntry: false) }
                }
            } else { addFile(url, role: role) }
        } catch { limitations.insert("production membership could not be read") }
    }

    func addFile(_ url: URL, role: NativeTargetDeclaredRole, countEntry: Bool = true) {
        if countEntry { entryCount += 1 }
        guard entryCount <= StjornarvaldNativeTargetMembership.maximumEntries else {
            limitations.insert("membership traversal exceeded its bound"); return
        }
        guard withinCaptureDeadline() else { return }
        guard contained(url) else {
            limitations.insert("membership path is outside the project"); return
        }
        guard let path = relativePath(url, from: root) else {
            limitations.insert("membership path is outside the project"); return
        }
        guard path.utf8.count <= 4_096 else { limitations.insert("membership path exceeded its bound"); return }
        let oldRoles = declaredPathRoles[path] ?? []
        let nextRoles = oldRoles.union([role])
        guard nextRoles != oldRoles else { return }
        let encoder = JSONEncoder()
        guard let encodedPath = try? encoder.encode(path),
              let encodedRoles = try? encoder.encode(nextRoles.sorted { $0.rawValue < $1.rawValue }),
              let encodedOldRoles = try? encoder.encode(oldRoles.sorted { $0.rawValue < $1.rawValue }) else {
            limitations.insert("membership role payload could not be encoded"); return
        }
        let addedPathBytes = paths.contains(path) ? 0 : encodedPath.count + 1
        guard addedPathBytes <= StjornarvaldNativeTargetMembership.maximumPathPayloadBytes,
              pathPayloadBytes <= StjornarvaldNativeTargetMembership.maximumPathPayloadBytes - addedPathBytes else {
            limitations.insert("membership path payload exceeded its transport budget"); return
        }
        let oldRoleBytes = oldRoles.isEmpty ? 0 : encodedPath.count + encodedOldRoles.count + 2
        let nextRoleBytes = encodedPath.count + encodedRoles.count + 2
        let addedRoleBytes = nextRoleBytes - oldRoleBytes
        let addedBytes = addedPathBytes + addedRoleBytes
        guard addedBytes <= StjornarvaldNativeTargetMembership.maximumMembershipPayloadBytes,
              pathPayloadBytes + rolePayloadBytes <=
                StjornarvaldNativeTargetMembership.maximumMembershipPayloadBytes - addedBytes else {
            limitations.insert("membership path payload exceeded its transport budget")
            limitations.insert("membership path/role payload exceeded its transport budget"); return
        }
        pathPayloadBytes += addedPathBytes
        rolePayloadBytes += addedRoleBytes
        paths.insert(path)
        declaredPathRoles[path] = nextRoles
    }

    func contained(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    func relativePath(_ url: URL, from base: URL) -> String? {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let baseComponents = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.starts(with: baseComponents), components.count > baseComponents.count else { return nil }
        return components.dropFirst(baseComponents.count).joined(separator: "/")
    }

    static let productionTypes: Set<String> = [
        "com.apple.product-type.application", "com.apple.product-type.framework",
        "com.apple.product-type.tool", "com.apple.product-type.library.static",
        "com.apple.product-type.library.dynamic", "com.apple.product-type.bundle",
        "com.apple.product-type.app-extension", "com.apple.product-type.xpc-service",
        "com.apple.product-type.system-extension",
    ]
    static let childGroupTypes: Set<String> = ["PBXGroup", "PBXVariantGroup", "XCVersionGroup"]
    private enum MembershipReadError: Error { case byteBound, unsupportedFile }
}

private final class WorkspaceMembershipReferences: NSObject, XMLParserDelegate {
    var paths: [String] = []
    var unsupported = false
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "Workspace" || elementName == "FileRef" else {
            unsupported = true; return
        }
        guard elementName == "FileRef" else { return }
        guard let location = attributes["location"], location.utf8.count <= 4_096,
              paths.count < StjornarvaldNativeTargetMembership.maximumProjects,
              let separator = location.firstIndex(of: ":"),
              ["group", "container"].contains(String(location[..<separator])) else {
            unsupported = true; return
        }
        let path = String(location[location.index(after: separator)...])
        guard !path.hasPrefix("/"), path.hasSuffix(".xcodeproj") else { unsupported = true; return }
        paths.append(path)
    }
}

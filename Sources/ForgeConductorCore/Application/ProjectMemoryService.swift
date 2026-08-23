// ProjectMemoryService.swift
// What: Resolves durable project identity and applies memory validation, redaction, and budgets.
// How: A bounded repository cache opens isolated project databases under application support.
// Why: MCP callers need one policy boundary that cannot cross project stores by path confusion.

import Foundation
import Darwin

private struct ProjectRegistryFile: Codable {
    var schemaVersion: Int
    var projects: [ProjectRegistryEntry]
}

private struct ProjectRegistryEntry: Codable {
    var id: String
    var displayName: String
    var repositoryIdentity: String?
    var aliases: [String]
    var createdAt: String
    var updatedAt: String
}

public final class ProjectIdentityResolver: @unchecked Sendable {
    private let paths: AppPaths
    private let lock = NSLock()
    private let clock: any Clock

    public init(paths: AppPaths, clock: any Clock = SystemClock()) {
        self.paths = paths
        self.clock = clock
    }

    public func initialize(
        path rawPath: String,
        projectID requestedID: String?,
        displayName: String?,
        repositoryIdentity suppliedRepositoryIdentity: String?
    ) throws -> ProjectMemoryDescriptor {
        let canonical = try canonicalDirectory(rawPath)
        let repositoryIdentity = normalized(suppliedRepositoryIdentity) ?? inferredRepositoryIdentity(canonical)
        return try withRegistryLock {
            var registry = try loadRegistry()
            let now = ISO8601.string(from: clock.now())
            let requested = normalized(requestedID)
            if let requested, UUID(uuidString: requested) == nil {
                throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
            }

            var index: Int?
            if let requested {
                index = registry.projects.firstIndex { $0.id.caseInsensitiveCompare(requested) == .orderedSame }
                guard index != nil else { throw ProjectMemoryError.projectNotFound(requested) }
            } else if let repositoryIdentity {
                index = registry.projects.firstIndex { $0.repositoryIdentity == repositoryIdentity }
            }
            if index == nil {
                index = registry.projects.firstIndex { $0.aliases.contains(canonical.path) }
            }

            if let index {
                var entry = registry.projects[index]
                if let repositoryIdentity, let existing = entry.repositoryIdentity,
                   existing != repositoryIdentity {
                    throw ProjectMemoryError.projectScopeMismatch
                }
                if !entry.aliases.contains(canonical.path) { entry.aliases.append(canonical.path) }
                entry.aliases = Array(entry.aliases.suffix(32))
                if entry.repositoryIdentity == nil { entry.repositoryIdentity = repositoryIdentity }
                if let name = normalized(displayName) { entry.displayName = name }
                entry.updatedAt = now
                registry.projects[index] = entry
                try save(registry)
                try writeMetadata(entry)
                return descriptor(entry)
            }

            let id = UUID().uuidString.lowercased()
            let entry = ProjectRegistryEntry(
                id: id,
                displayName: normalized(displayName) ?? canonical.lastPathComponent,
                repositoryIdentity: repositoryIdentity,
                aliases: [canonical.path],
                createdAt: now,
                updatedAt: now
            )
            registry.projects.append(entry)
            try save(registry)
            try writeMetadata(entry)
            return descriptor(entry)
        }
    }

    public func descriptor(projectID: String) throws -> ProjectMemoryDescriptor {
        try withRegistryLock {
            let registry = try loadRegistry()
            guard let entry = registry.projects.first(where: { $0.id == projectID }) else {
                throw ProjectMemoryError.projectNotFound(projectID)
            }
            return descriptor(entry)
        }
    }

    public func projectDirectory(projectID: String) throws -> URL {
        _ = try descriptor(projectID: projectID)
        let directory = paths.projectsDir.appendingPathComponent(projectID, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == paths.projectsDir.standardizedFileURL else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        return directory
    }

    private func canonicalDirectory(_ rawPath: String) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectMemoryError.invalidRequest("project_path is required")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectMemoryError.invalidRequest("project_path must name an existing directory")
        }
        return url
    }

    private func inferredRepositoryIdentity(_ project: URL) -> String? {
        let config = project.appendingPathComponent(".git/config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        let remotes = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("url =") }
            .sorted()
        guard !remotes.isEmpty else { return nil }
        return "git:" + JSONSupport.sha256Hex(remotes.joined(separator: "\n"))
    }

    private func loadRegistry() throws -> ProjectRegistryFile {
        guard FileManager.default.fileExists(atPath: paths.projectRegistry.path) else {
            return ProjectRegistryFile(schemaVersion: 1, projects: [])
        }
        let data = try Data(contentsOf: paths.projectRegistry)
        let registry = try JSONDecoder().decode(ProjectRegistryFile.self, from: data)
        guard registry.schemaVersion == 1 else {
            throw ProjectMemoryError.unsupportedVersion(registry.schemaVersion)
        }
        return registry
    }

    private func save(_ registry: ProjectRegistryFile) throws {
        let data = try JSONEncoder.sorted.encode(registry)
        try data.write(to: paths.projectRegistry, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.projectRegistry.path)
    }

    private func writeMetadata(_ entry: ProjectRegistryEntry) throws {
        let directory = paths.projectsDir.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.sorted.encode(entry)
        let url = directory.appendingPathComponent("project.json")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func withRegistryLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let lockURL = paths.projectsDir.appendingPathComponent(".registry.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProjectMemoryError.databaseBusy }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ProjectMemoryError.databaseBusy }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func descriptor(_ entry: ProjectRegistryEntry) -> ProjectMemoryDescriptor {
        ProjectMemoryDescriptor(
            id: entry.id, displayName: entry.displayName,
            repositoryIdentity: entry.repositoryIdentity, aliases: entry.aliases
        )
    }
}

public struct ProjectMemoryRedactor: Sendable {
    private static let patterns: [String] = [
        #"(?i)authorization:\s*(bearer|basic)\s+[A-Za-z0-9._~+\-/=]+"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
        #"\bAKIA[A-Z0-9]{16}\b"#,
        #"(?i)\b(api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,;]+"#,
    ]

    public init() {}

    public func redact(_ value: String?) throws -> String? {
        guard var output = value else { return nil }
        if output.contains("-----BEGIN PRIVATE KEY-----") || output.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { // Redaction patterns.
            throw ProjectMemoryError.redactionRejected("private key material is not accepted")
        }
        for pattern in Self.patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "<redacted>")
        }
        return output
    }
}

public final class ProjectMemoryService: @unchecked Sendable {
    public static let capabilityVersion = 1
    public let limits: ProjectMemoryLimits
    public let identities: ProjectIdentityResolver
    private let paths: AppPaths
    private let clock: any Clock
    private let redactor = ProjectMemoryRedactor()
    private let lock = NSLock()
    private var repositories: [String: ProjectMemoryRepository] = [:]
    private var repositoryOrder: [String] = []

    public init(paths: AppPaths, clock: any Clock = SystemClock(), limits: ProjectMemoryLimits = .current) {
        self.paths = paths
        self.clock = clock
        self.limits = limits
        self.identities = ProjectIdentityResolver(paths: paths, clock: clock)
    }

    deinit { closeAll() }

    public func closeAll() {
        lock.lock()
        let values = Array(repositories.values)
        repositories.removeAll()
        repositoryOrder.removeAll()
        lock.unlock()
        values.forEach { $0.close() }
    }

    public func initialize(
        path: String,
        projectID: String? = nil,
        displayName: String? = nil,
        repositoryIdentity: String? = nil
    ) throws -> [String: Any] {
        let descriptor = try identities.initialize(
            path: path, projectID: projectID, displayName: displayName,
            repositoryIdentity: repositoryIdentity
        )
        let repository = try self.repository(projectID: descriptor.id)
        return [
            "ok": true,
            "project_id": descriptor.id,
            "schema_version": ProjectMemoryRepository.schemaVersion,
            "capability_version": Self.capabilityVersion,
            "capabilities": ["lexical_search", "transactions", "redaction", "exports", repository.supportsFTS5 ? "fts5" : "bounded_sql_fallback"],
            "limits": limits.asDictionary(),
            "migration_status": "current",
            "project": descriptor.asDictionary(),
        ]
    }

    public func remember(projectID: String, write: ProjectMemoryWrite) throws -> [String: Any] {
        let validated = try validate(write)
        let (record, disposition) = try repository(projectID: projectID).remember(validated)
        return writeResult(record, disposition: disposition)
    }

    public func rememberBatch(projectID: String, writes: [ProjectMemoryWrite]) throws -> [String: Any] {
        guard !writes.isEmpty, writes.count <= limits.maximumBatchCount else {
            throw ProjectMemoryError.payloadTooLarge("batch count exceeds \(limits.maximumBatchCount)")
        }
        let validated = try writes.map(validate)
        let encodedBytes = validated.reduce(0) { total, item in
            total + item.title.utf8.count + item.summary.utf8.count + (item.body?.utf8.count ?? 0)
        }
        guard encodedBytes <= limits.maximumBatchBytes else {
            throw ProjectMemoryError.payloadTooLarge("batch bytes exceed \(limits.maximumBatchBytes)")
        }
        let results = try repository(projectID: projectID).rememberBatch(validated)
        return [
            "ok": true,
            "project_id": projectID,
            "count": results.count,
            "results": results.map { writeResult($0.0, disposition: $0.1) },
            "schema_version": ProjectMemoryRepository.schemaVersion,
            "capability_version": Self.capabilityVersion,
        ]
    }

    public func get(projectID: String, ids: [String], includeBody: Bool) throws -> [String: Any] {
        guard !ids.isEmpty, ids.count <= limits.maximumPageCount else {
            throw ProjectMemoryError.invalidRequest("ids must contain 1...\(limits.maximumPageCount) values")
        }
        let records = try repository(projectID: projectID).get(ids: ids, includeBody: includeBody, maximumCount: limits.maximumPageCount)
        return envelope(projectID: projectID, records: records.map { $0.asDictionary(includeBody: includeBody) })
    }

    public func update(
        projectID: String,
        id: String,
        expectedVersion: Int,
        title: String?, summary: String?, body: String?, tags: [String]?
    ) throws -> [String: Any] {
        if let title { try requireBytes(title, maximum: limits.maximumTitleBytes, field: "title") }
        if let summary { try requireBytes(summary, maximum: limits.maximumSummaryBytes, field: "summary") }
        if let body { try requireBytes(body, maximum: limits.maximumBodyBytes, field: "body") }
        let redactedTitle = try redactor.redact(title)
        let redactedSummary = try redactor.redact(summary)
        let redactedBody = try redactor.redact(body)
        let normalizedTags = try tags.map(normalizeTags)
        let record = try repository(projectID: projectID).update(
            id: id, expectedVersion: expectedVersion, title: redactedTitle,
            summary: redactedSummary, body: redactedBody, tags: normalizedTags
        )
        return ["ok": true, "record": record.asDictionary(includeBody: true), "schema_version": ProjectMemoryRepository.schemaVersion]
    }

    public func forget(projectID: String, id: String) throws -> [String: Any] {
        let deleted = try repository(projectID: projectID).forget(id: id)
        return ["ok": true, "project_id": projectID, "record_id": id, "disposition": deleted ? "tombstoned" : "not_found"]
    }

    public func link(projectID: String, sourceID: String, targetID: String, relation: String) throws -> [String: Any] {
        let normalizedRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRelation.isEmpty, normalizedRelation.utf8.count <= 128 else {
            throw ProjectMemoryError.invalidRequest("relation must contain 1...128 bytes")
        }
        let inserted = try repository(projectID: projectID).link(sourceID: sourceID, targetID: targetID, relation: normalizedRelation)
        return ["ok": true, "project_id": projectID, "disposition": inserted ? "inserted" : "deduplicated"]
    }

    public func listRecent(
        projectID: String, kinds: [String], sessionID: String?, limit: Int, cursor: String?, includeBody: Bool,
        maximumResponseBytes: Int
    ) throws -> [String: Any] {
        let page = min(max(limit, 1), limits.maximumPageCount)
        let offset = try decodeCursor(cursor)
        let records = try repository(projectID: projectID).recent(kinds: kinds, sessionID: sessionID, limit: page + 1, offset: offset)
        return boundedPage(projectID: projectID, records: records.map { $0.asDictionary(includeBody: includeBody) }, offset: offset, requestedPage: page, maximumBytes: maximumResponseBytes)
    }

    public func search(
        projectID: String, query: String, kinds: [String], tags: [String], sessionID: String?,
        limit: Int, cursor: String?, includeBody: Bool, maximumResponseBytes: Int
    ) throws -> [String: Any] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProjectMemoryError.invalidRequest("query is required") }
        try requireBytes(normalized, maximum: limits.maximumQueryBytes, field: "query")
        let page = min(max(limit, 1), limits.maximumPageCount)
        let offset = try decodeCursor(cursor)
        let matches = try repository(projectID: projectID).search(
            query: normalized, kinds: kinds, tags: try normalizeTags(tags), sessionID: sessionID,
            limit: page + 1, offset: offset
        )
        let records = matches.map { $0.0.asDictionary(includeBody: includeBody, score: $0.1) }
        var output = boundedPage(projectID: projectID, records: records, offset: offset, requestedPage: page, maximumBytes: maximumResponseBytes)
        output["query"] = normalized
        output["ranking"] = ["exact_id", "exact_title", "lexical_title", "summary", "body", "importance", "confidence"]
        return output
    }

    public func status(projectID: String) throws -> [String: Any] {
        var status = try repository(projectID: projectID).status()
        status["ok"] = true
        status["capability_version"] = Self.capabilityVersion
        status["limits"] = limits.asDictionary()
        status["cache"] = ["open_repositories": openRepositoryCount, "maximum": limits.maximumOpenProjects]
        return status
    }

    public func export(projectID: String) throws -> [String: Any] {
        let repository = try repository(projectID: projectID)
        let records = try repository.exportRecords()
        let recordsData = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        guard recordsData.count <= 32 * 1024 * 1024 else {
            throw ProjectMemoryError.payloadTooLarge("export exceeds 32 MiB artifact limit")
        }
        let checksum = JSONSupport.sha256Hex(String(data: recordsData, encoding: .utf8) ?? "")
        let payload: [String: Any] = [
            "schema_version": ProjectMemoryRepository.schemaVersion,
            "project_id": projectID,
            "created_at": ISO8601.string(from: clock.now()),
            "checksum": checksum,
            "records": records,
        ]
        let exports = repository.directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let artifact = exports.appendingPathComponent("memory-export-\(UUID().uuidString.lowercased()).json")
        try JSONSupport.data(from: payload).write(to: artifact, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
        return ["ok": true, "project_id": projectID, "artifact": artifact.path, "checksum": checksum, "record_count": records.count]
    }

    public func importRecords(projectID: String, artifactPath: String, preview: Bool, mergePolicy: String?) throws -> [String: Any] {
        let repository = try repository(projectID: projectID)
        let artifact = URL(fileURLWithPath: artifactPath).resolvingSymlinksInPath().standardizedFileURL
        let exports = repository.directory.appendingPathComponent("exports", isDirectory: true).standardizedFileURL
        guard artifact.pathComponents.starts(with: exports.pathComponents) else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        let payload = try JSONSupport.object(from: Data(contentsOf: artifact))
        guard payload["schema_version"] as? Int == ProjectMemoryRepository.schemaVersion,
              let sourceProject = payload["project_id"] as? String,
              let records = payload["records"] as? [[String: Any]],
              let expectedChecksum = payload["checksum"] as? String else {
            throw ProjectMemoryError.invalidRequest("invalid export artifact")
        }
        let recordsData = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let actualChecksum = JSONSupport.sha256Hex(String(data: recordsData, encoding: .utf8) ?? "")
        guard actualChecksum == expectedChecksum else { throw ProjectMemoryError.integrityFailure("export checksum mismatch") }
        guard records.count <= limits.maximumBatchCount else {
            throw ProjectMemoryError.payloadTooLarge("import exceeds \(limits.maximumBatchCount) records")
        }
        if sourceProject != projectID, mergePolicy != "merge" {
            throw ProjectMemoryError.projectScopeMismatch
        }
        let writes = try records.prefix(limits.maximumBatchCount).map(writeFromExport)
        if preview {
            return ["ok": true, "preview": true, "project_id": projectID, "record_count": records.count, "importable_count": writes.count, "checksum": actualChecksum]
        }
        return try rememberBatch(projectID: projectID, writes: writes)
    }

    public var openRepositoryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return repositories.count
    }

    /// Shared durable adapter for continuity and maintenance components. The
    /// service still enforces project identity and its bounded repository cache.
    public func repositoryForProject(_ projectID: String) throws -> ProjectMemoryRepository {
        try repository(projectID: projectID)
    }

    private func repository(projectID: String) throws -> ProjectMemoryRepository {
        _ = try identities.descriptor(projectID: projectID)
        lock.lock()
        if let existing = repositories[projectID] {
            repositoryOrder.removeAll { $0 == projectID }
            repositoryOrder.append(projectID)
            lock.unlock()
            return existing
        }
        lock.unlock()
        let created = try ProjectMemoryRepository(
            projectID: projectID, directory: identities.projectDirectory(projectID: projectID), clock: clock
        )
        lock.lock()
        if let raced = repositories[projectID] {
            lock.unlock(); created.close(); return raced
        }
        repositories[projectID] = created
        repositoryOrder.append(projectID)
        var evicted: ProjectMemoryRepository?
        if repositoryOrder.count > limits.maximumOpenProjects {
            let oldest = repositoryOrder.removeFirst()
            evicted = repositories.removeValue(forKey: oldest)
        }
        lock.unlock()
        evicted?.close()
        return created
    }

    private func validate(_ write: ProjectMemoryWrite) throws -> ProjectMemoryWrite {
        let kind = write.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kind.isEmpty, kind.utf8.count <= 64,
              kind.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }) else {
            throw ProjectMemoryError.invalidRequest("kind must contain 1...64 identifier bytes")
        }
        let title = write.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = write.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !summary.isEmpty else { throw ProjectMemoryError.invalidRequest("title and summary are required") }
        try requireBytes(title, maximum: limits.maximumTitleBytes, field: "title")
        try requireBytes(summary, maximum: limits.maximumSummaryBytes, field: "summary")
        if let body = write.body { try requireBytes(body, maximum: limits.maximumBodyBytes, field: "body") }
        if let reference = write.sourceReference { try requireBytes(reference, maximum: limits.maximumSourceReferenceBytes, field: "source_reference") }
        guard (0...1).contains(write.importance), (0...1).contains(write.confidence) else {
            throw ProjectMemoryError.invalidRequest("importance and confidence must be within 0...1")
        }
        let tags = try normalizeTags(write.tags)
        return ProjectMemoryWrite(
            kind: kind, title: try redactor.redact(title) ?? title,
            summary: try redactor.redact(summary) ?? summary, body: try redactor.redact(write.body),
            tags: tags, importance: write.importance, confidence: write.confidence,
            sourceKind: write.sourceKind, sourceReference: try redactor.redact(write.sourceReference),
            sessionID: write.sessionID, expiresAt: write.expiresAt,
            relatedIDs: Array(write.relatedIDs.prefix(32)), idempotencyKey: write.idempotencyKey
        )
    }

    private func normalizeTags(_ tags: [String]) throws -> [String] {
        guard tags.count <= limits.maximumTagCount else { throw ProjectMemoryError.payloadTooLarge("too many tags") }
        var output: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !tag.isEmpty else { continue }
            try requireBytes(tag, maximum: limits.maximumTagBytes, field: "tag")
            if !output.contains(tag) { output.append(tag) }
        }
        return output.sorted()
    }

    private func requireBytes(_ value: String, maximum: Int, field: String) throws {
        guard value.utf8.count <= maximum else {
            throw ProjectMemoryError.payloadTooLarge("\(field) exceeds \(maximum) bytes")
        }
    }

    private func writeResult(_ record: ProjectMemoryRecord, disposition: String) -> [String: Any] {
        [
            "ok": true, "project_id": record.projectID, "record_id": record.id,
            "record_version": record.version, "disposition": disposition,
            "content_hash": record.contentHash, "schema_version": ProjectMemoryRepository.schemaVersion,
            "capability_version": Self.capabilityVersion,
        ]
    }

    private func envelope(projectID: String, records: [[String: Any]]) -> [String: Any] {
        ["ok": true, "project_id": projectID, "count": records.count, "records": records,
         "schema_version": ProjectMemoryRepository.schemaVersion, "capability_version": Self.capabilityVersion]
    }

    private func boundedPage(
        projectID: String, records: [[String: Any]], offset: Int, requestedPage: Int, maximumBytes: Int
    ) -> [String: Any] {
        let byteLimit = min(max(maximumBytes, 1024), limits.maximumResponseBytes)
        var accepted: [[String: Any]] = []
        var used = 256
        var truncated = records.count > requestedPage
        for record in records.prefix(requestedPage) {
            let size = (try? JSONSerialization.data(withJSONObject: record).count) ?? byteLimit
            if used + size > byteLimit { truncated = true; break }
            accepted.append(record); used += size
        }
        let nextOffset = offset + accepted.count
        return [
            "ok": true, "project_id": projectID, "count": accepted.count, "records": accepted,
            "next_cursor": truncated && !accepted.isEmpty ? encodeCursor(nextOffset) : NSNull(),
            "truncated": truncated, "encoded_bytes": used, "maximum_response_bytes": byteLimit,
            "schema_version": ProjectMemoryRepository.schemaVersion, "capability_version": Self.capabilityVersion,
        ]
    }

    private func encodeCursor(_ offset: Int) -> String { Data("v1:\(offset)".utf8).base64EncodedString() }

    private func decodeCursor(_ cursor: String?) throws -> Int {
        guard let cursor, !cursor.isEmpty else { return 0 }
        guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8),
              text.hasPrefix("v1:"), let value = Int(text.dropFirst(3)), value >= 0 else {
            throw ProjectMemoryError.invalidRequest("invalid cursor")
        }
        return value
    }

    private func writeFromExport(_ object: [String: Any]) throws -> ProjectMemoryWrite {
        guard let kind = object["kind"] as? String, let title = object["title"] as? String,
              let summary = object["summary"] as? String else {
            throw ProjectMemoryError.invalidRequest("export record is missing required fields")
        }
        return ProjectMemoryWrite(
            kind: kind, title: title, summary: summary, body: object["body"] as? String,
            tags: object["tags"] as? [String] ?? [], importance: object["importance"] as? Double ?? 0.5,
            confidence: object["confidence"] as? Double ?? 1,
            sourceKind: object["source_kind"] as? String ?? "imported_artifact",
            sourceReference: object["source_reference"] as? String,
            sessionID: object["session_id"] as? String, expiresAt: object["expires_at"] as? String,
            idempotencyKey: "import:\(object["content_hash"] as? String ?? UUID().uuidString)"
        )
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

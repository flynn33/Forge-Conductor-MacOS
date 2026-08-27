// DiagnosticLog.swift
// What: Implements the append-only structured diagnostic event store and exporter.
// How: Thread-safe JSONL writes feed bounded recent reads, severity/category envelopes,
// and paired machine-readable JSON plus operator-readable Markdown exports.
// Why: Failures need durable, correlatable evidence across short-lived process roles.

import Foundation
import Synchronization

/// Capacity-limited serial work owner used by persistence mirrors that must not
/// retain their caller while filesystem or database I/O is slow.
final class BoundedAsyncWorkQueue: @unchecked Sendable {
    let capacity: Int

    private let queue: DispatchQueue
    private let slots: DispatchSemaphore
    private let pending = DispatchGroup()
    private let admissionLock = NSLock()
    private let dropped = Atomic<Int>(0)
    private var accepting = true

    init(label: String, capacity: Int) {
        self.capacity = max(1, min(capacity, 4_096))
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.slots = DispatchSemaphore(value: self.capacity)
    }

    @discardableResult
    func submit(_ work: @escaping @Sendable () -> Void) -> Bool {
        // The response path never waits for admission or queue capacity.
        guard admissionLock.try() else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        defer { admissionLock.unlock() }
        guard accepting,
              slots.wait(timeout: .now()) == .success else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }

        pending.enter()
        let pending = self.pending
        let slots = self.slots
        queue.async {
            defer {
                slots.signal()
                pending.leave()
            }
            work()
        }
        return true
    }

    @discardableResult
    func flush(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(Self.bounded(timeout))
        guard admissionLock.lock(before: deadline) else { return false }
        defer { admissionLock.unlock() }
        return pending.wait(
            timeout: .now() + max(0, deadline.timeIntervalSinceNow)
        ) == .success
    }

    @discardableResult
    func shutdown(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(Self.bounded(timeout))
        guard admissionLock.lock(before: deadline) else { return false }
        defer { admissionLock.unlock() }
        accepting = false
        return pending.wait(
            timeout: .now() + max(0, deadline.timeIntervalSinceNow)
        ) == .success
    }

    var droppedSubmissions: Int {
        dropped.load(ordering: .relaxed)
    }

    private static func bounded(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return 30 }
        return min(30, max(0, timeout))
    }
}

public enum DiagnosticRedaction {
    private static let privateKeys: Set<String> = [
        "body", "command", "content", "cwd", "error", "goal", "home", "json",
        "markdown", "narrative", "password", "path", "prompt", "query", "secret",
        "summary", "token",
    ]

    public static func fields(_ fields: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { key, value in
            (key, redactedValue(value, forKey: key))
        })
    }

    public static func redactedValue(_ value: String, forKey key: String) -> String {
        let normalized = key.lowercased()
        let isPrivateKey = privateKeys.contains(normalized)
            || normalized.hasSuffix("_path")
            || normalized.contains("credential")
        let looksLikePath = value.hasPrefix("/")
            || value.hasPrefix("file://")
            || value.contains("/Users/")
        if isPrivateKey || looksLikePath {
            return "<redacted:\(value.utf8.count)b>"
        }
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(flattened.prefix(512))
    }
}

/// Persistent, structured diagnostic logging for Forge Conductor.
///
/// - Append-only JSONL on disk under `~/.forge-conductor/logs/`
/// - In-memory ring for recent UI inspection
/// - Export to `.json` (structured array) and `.md` (operator-readable)
public final class DiagnosticLog: DiagnosticRecording, @unchecked Sendable {
    public static let masterLogName = "forge-diagnostics.jsonl"
    public static let ringCapacity = 4_000
    public static let persistenceQueueCapacity = 256
    /// Rotate master JSONL when larger than this (bytes).
    public static let maxMasterLogBytes: UInt64 = 8 * 1024 * 1024

    private let paths: AppPaths
    private let role: String
    private let ringLimit: Int
    private let maximumLogBytes: UInt64
    private let retainedArchives: Int
    private let ringState: DiagnosticRingState
    private let persistenceWriter: DiagnosticPersistenceWriter
    private let persistenceQueue: BoundedAsyncWorkQueue

    public init(paths: AppPaths, role: String = "primary") {
        self.paths = paths
        self.role = role
        let limits = ResourcePolicy.current.nominalLimits
        self.ringLimit = min(Self.ringCapacity, limits.diagnosticRingRecords)
        self.maximumLogBytes = min(Self.maxMasterLogBytes, limits.logFileBytes)
        self.retainedArchives = limits.retainedLogArchives
        self.ringState = DiagnosticRingState(limit: self.ringLimit)
        self.persistenceWriter = DiagnosticPersistenceWriter(
            paths: paths,
            maximumLogBytes: self.maximumLogBytes,
            retainedArchives: self.retainedArchives,
            beforePersistence: nil
        )
        self.persistenceQueue = BoundedAsyncWorkQueue(
            label: "forge.diagnostics.persistence",
            capacity: Self.persistenceQueueCapacity
        )
    }

    init(
        paths: AppPaths,
        role: String = "primary",
        ringLimit: Int,
        maximumLogBytes: UInt64,
        retainedArchives: Int,
        persistenceQueueCapacity: Int = DiagnosticLog.persistenceQueueCapacity,
        beforePersistence: (@Sendable () -> Void)? = nil
    ) {
        self.paths = paths
        self.role = role
        self.ringLimit = max(1, ringLimit)
        self.maximumLogBytes = max(1, maximumLogBytes)
        self.retainedArchives = max(0, retainedArchives)
        self.ringState = DiagnosticRingState(limit: self.ringLimit)
        self.persistenceWriter = DiagnosticPersistenceWriter(
            paths: paths,
            maximumLogBytes: self.maximumLogBytes,
            retainedArchives: self.retainedArchives,
            beforePersistence: beforePersistence
        )
        self.persistenceQueue = BoundedAsyncWorkQueue(
            label: "forge.diagnostics.persistence.\(UUID().uuidString)",
            capacity: persistenceQueueCapacity
        )
    }

    deinit {
        _ = persistenceQueue.shutdown(timeout: 0.25)
    }

    // MARK: - Write

    public func log(_ record: DiagnosticRecord) {
        let envelope = DiagnosticEnvelope(
            ts: record.ts,
            event: record.event,
            severity: record.severity,
            role: record.role.isEmpty ? role : record.role,
            pid: ProcessInfo.processInfo.processIdentifier,
            category: record.category,
            fields: DiagnosticRedaction.fields(record.fields)
        )

        // Preserve the ring immediately when uncontended. If a concurrent reader
        // owns its short memory-only lock, the persistence worker completes the
        // append instead of making this caller wait.
        let ringWasUpdated = ringState.tryAppend(envelope)
        let ringState = self.ringState
        let writer = persistenceWriter
        _ = persistenceQueue.submit {
            if !ringWasUpdated {
                ringState.append(envelope)
            }
            do {
                try writer.persist(envelope)
            } catch {
                fputs("diagnostic log error: \(error)\n", stderr)
            }
        }
    }

    /// Bounded drain for exports, deterministic tests, and explicit owner shutdown.
    @discardableResult
    public func flush(timeout: TimeInterval = 2) -> Bool {
        persistenceQueue.flush(timeout: timeout)
    }

    /// Stops accepting persistence work and waits only through the supplied bound.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 2) -> Bool {
        persistenceQueue.shutdown(timeout: timeout)
    }

    var droppedPersistenceCount: Int { persistenceQueue.droppedSubmissions }

    public func info(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .info, role: role, category: category, fields: fields))
    }

    public func warn(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .warn, role: role, category: category, fields: fields))
    }

    public func error(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .error, role: role, category: category, fields: fields))
    }

    public func critical(_ event: String, _ fields: [String: String] = [:], category: DiagnosticCategory = .general) {
        log(DiagnosticRecord(event: event, severity: .critical, role: role, category: category, fields: fields))
    }

    // MARK: - Read

    /// Recent records from the in-memory ring (newest last).
    public func recent(limit: Int = 200) -> [DiagnosticEnvelope] {
        ringState.snapshot(limit: limit)
    }

    /// Load all on-disk master JSONL records (best-effort; large files may be capped).
    public func loadPersisted(maxLines: Int = 50_000) throws -> [DiagnosticEnvelope] {
        guard flush(timeout: 2) else {
            throw DiagnosticExportError.persistenceBusy
        }
        let url = paths.masterDiagnostics
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [DiagnosticEnvelope] = []
        out.reserveCapacity(min(maxLines, 4_096))
        for line in text.split(whereSeparator: \.isNewline).suffix(maxLines) {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, let data = s.data(using: .utf8) else { continue }
            if var env = try? JSONDecoder().decode(DiagnosticEnvelope.self, from: data) {
                env.fields = DiagnosticRedaction.fields(env.fields)
                out.append(env)
            }
        }
        return out
    }

    // MARK: - Export

    public struct ExportResult: Sendable, Equatable {
        public var jsonURL: URL
        public var markdownURL: URL
        public var recordCount: Int
        public var exportedAt: Date
    }

    /// Write a point-in-time export combining ring + disk into JSON + Markdown.
    public func export(
        to directory: URL? = nil,
        basename: String? = nil
    ) throws -> ExportResult {
        try paths.ensureLayout()
        let dir = directory ?? paths.exportsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var merged = try loadPersisted()
        let live = ringState.snapshot(limit: .max)
        // Prefer disk order; append any ring entries not already present by (ts,event,pid)
        let seen = Set(merged.map(\.identityKey))
        for e in live where !seen.contains(e.identityKey) {
            merged.append(e)
        }
        merged.sort { $0.ts < $1.ts }

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let name = basename ?? "forge-diagnostics-\(Self.fileStamp())"
        let jsonURL = dir.appendingPathComponent("\(name).json")
        let mdURL = dir.appendingPathComponent("\(name).md")

        let payload: [String: Any] = [
            "product": ForgeApp.productName,
            "version": ForgeApp.version,
            "exported_at": stamp.string(from: Date()),
            "home": DiagnosticRedaction.redactedValue(paths.home.path, forKey: "home"),
            "record_count": merged.count,
            "records": merged.map { $0.asDictionary() },
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: jsonURL, options: .atomic)

        let md = Self.renderMarkdown(
            product: ForgeApp.productName,
            version: ForgeApp.version,
            home: DiagnosticRedaction.redactedValue(paths.home.path, forKey: "home"),
            records: merged
        )
        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        info("diagnostics_exported", [
            "json": jsonURL.path,
            "markdown": mdURL.path,
            "count": "\(merged.count)",
        ], category: .diagnostics)

        return ExportResult(
            jsonURL: jsonURL,
            markdownURL: mdURL,
            recordCount: merged.count,
            exportedAt: Date()
        )
    }

    // MARK: - Private

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func renderMarkdown(
        product: String,
        version: String,
        home: String,
        records: [DiagnosticEnvelope]
    ) -> String {
        var lines: [String] = []
        lines.append("# \(product) Diagnostic Export")
        lines.append("")
        lines.append("- **Version:** \(version)")
        lines.append("- **Home:** `\(home)`")
        lines.append("- **Exported:** \(ISO8601.string(from: Date()))")
        lines.append("- **Records:** \(records.count)")
        lines.append("")
        lines.append("## Summary by severity")
        lines.append("")
        var bySev: [String: Int] = [:]
        var byCat: [String: Int] = [:]
        for r in records {
            bySev[r.severity.rawValue, default: 0] += 1
            byCat[r.category.rawValue, default: 0] += 1
        }
        for k in bySev.keys.sorted() {
            lines.append("- \(k): \(bySev[k] ?? 0)")
        }
        lines.append("")
        lines.append("## Summary by category")
        lines.append("")
        for k in byCat.keys.sorted() {
            lines.append("- \(k): \(byCat[k] ?? 0)")
        }
        lines.append("")
        lines.append("## Timeline")
        lines.append("")
        lines.append("| Time (UTC) | Severity | Category | Event | Fields |")
        lines.append("|---|---|---|---|---|")
        for r in records.suffix(2_000) {
            let fields = r.fields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
                .replacingOccurrences(of: "|", with: "\\|")
            let event = r.event.replacingOccurrences(of: "|", with: "\\|")
            lines.append(
                "| \(r.tsISO) | \(r.severity.rawValue) | \(r.category.rawValue) | \(event) | \(fields) |"
            )
        }
        lines.append("")
        lines.append("_End of export._")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private final class DiagnosticRingState: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var records: [DiagnosticEnvelope] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func tryAppend(_ envelope: DiagnosticEnvelope) -> Bool {
        guard lock.try() else { return false }
        appendLocked(envelope)
        lock.unlock()
        return true
    }

    func append(_ envelope: DiagnosticEnvelope) {
        lock.lock()
        appendLocked(envelope)
        lock.unlock()
    }

    func snapshot(limit requestedLimit: Int) -> [DiagnosticEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return Array(records.suffix(max(0, min(requestedLimit, limit))))
    }

    private func appendLocked(_ envelope: DiagnosticEnvelope) {
        records.append(envelope)
        if records.count > limit {
            records.removeFirst(records.count - limit)
        }
    }
}

private final class DiagnosticPersistenceWriter: @unchecked Sendable {
    private let paths: AppPaths
    private let maximumLogBytes: UInt64
    private let retainedArchives: Int
    private let beforePersistence: (@Sendable () -> Void)?

    init(
        paths: AppPaths,
        maximumLogBytes: UInt64,
        retainedArchives: Int,
        beforePersistence: (@Sendable () -> Void)?
    ) {
        self.paths = paths
        self.maximumLogBytes = maximumLogBytes
        self.retainedArchives = retainedArchives
        self.beforePersistence = beforePersistence
    }

    func persist(_ envelope: DiagnosticEnvelope) throws {
        beforePersistence?()
        try paths.ensureLayout()
        let data = try envelope.jsonLine()
        try append(data, to: paths.masterDiagnostics)
        try append(data, to: paths.toolDiagnostics)

        if envelope.event.hasPrefix("agent_") || envelope.event == "agent_health" {
            try append(data, to: paths.agentDiagnostics)
        }
        if envelope.severity == .warn || envelope.severity == .error || envelope.severity == .critical
            || envelope.event.hasPrefix("agent_")
            || envelope.category == .mcp
            || envelope.category == .lmstudio {
            try append(data, to: paths.failoverDiagnostics)
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        try rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotateIfNeeded(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maximumLogBytes else { return }
        if retainedArchives > 0 {
            for generation in stride(from: retainedArchives, through: 2, by: -1) {
                let older = URL(fileURLWithPath: "\(url.path).\(generation - 1)")
                let newer = URL(fileURLWithPath: "\(url.path).\(generation)")
                if fileManager.fileExists(atPath: newer.path) {
                    try fileManager.removeItem(at: newer)
                }
                if fileManager.fileExists(atPath: older.path) {
                    try fileManager.moveItem(at: older, to: newer)
                }
            }
            let first = URL(fileURLWithPath: "\(url.path).1")
            if fileManager.fileExists(atPath: first.path) {
                try fileManager.removeItem(at: first)
            }
            try fileManager.moveItem(at: url, to: first)
        } else {
            try fileManager.removeItem(at: url)
        }
        fileManager.createFile(atPath: url.path, contents: nil)
    }
}

// MARK: - Models

public enum DiagnosticCategory: String, Sendable, Codable, CaseIterable {
    case general
    case bootstrap
    case telemetry
    case mcp
    case lmstudio
    case manager
    case tools
    case agent
    case diagnostics
    case ui
}

public enum DiagnosticExportError: Error, LocalizedError, Equatable {
    case cancelled
    case persistenceBusy

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Export cancelled"
        case .persistenceBusy: "Diagnostic persistence did not drain before the read deadline"
        }
    }
}

/// On-disk / export envelope (Codable).
public struct DiagnosticEnvelope: Sendable, Codable, Equatable {
    public var ts: Date
    public var event: String
    public var severity: DiagnosticSeverity
    public var role: String
    public var pid: Int32
    public var category: DiagnosticCategory
    public var fields: [String: String]

    public var tsISO: String { ISO8601.string(from: ts) }

    public var identityKey: String {
        "\(tsISO)|\(event)|\(pid)|\(role)"
    }

    public func asDictionary() -> [String: Any] {
        var obj: [String: Any] = [
            "ts": tsISO,
            "event": event,
            "severity": severity.rawValue,
            "role": role,
            "pid": Int(pid),
            "category": category.rawValue,
        ]
        if !fields.isEmpty {
            obj["fields"] = fields
        }
        return obj
    }

    public func jsonLine() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: asDictionary(), options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    enum CodingKeys: String, CodingKey {
        case ts, event, severity, role, pid, category, fields
    }

    public init(
        ts: Date,
        event: String,
        severity: DiagnosticSeverity,
        role: String,
        pid: Int32,
        category: DiagnosticCategory,
        fields: [String: String]
    ) {
        self.ts = ts
        self.event = event
        self.severity = severity
        self.role = role
        self.pid = pid
        self.category = category
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .ts), let d = ISO8601.date(from: s) {
            ts = d
        } else {
            ts = (try? c.decode(Date.self, forKey: .ts)) ?? Date()
        }
        event = try c.decode(String.self, forKey: .event)
        severity = (try? c.decode(DiagnosticSeverity.self, forKey: .severity)) ?? .info
        role = (try? c.decode(String.self, forKey: .role)) ?? "primary"
        if let i = try? c.decode(Int.self, forKey: .pid) {
            pid = Int32(i)
        } else {
            pid = (try? c.decode(Int32.self, forKey: .pid)) ?? 0
        }
        category = (try? c.decode(DiagnosticCategory.self, forKey: .category)) ?? .general
        fields = (try? c.decode([String: String].self, forKey: .fields)) ?? [:]
    }
}

// Extend DiagnosticRecord with category (backward compatible init below in Models)

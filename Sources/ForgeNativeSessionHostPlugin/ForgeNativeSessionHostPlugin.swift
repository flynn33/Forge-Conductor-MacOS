// ForgeNativeSessionHostPlugin.swift
// What: Implements the native logical-session host used for autonomous rollover.
// How: An injected transport performs provider work while a bounded local ledger reconciles retries.
// Why: Forge can create, bootstrap, acknowledge, cancel, and recover sessions without GUI automation.

import Foundation
#if SWIFT_PACKAGE
import ForgeConductorCore
#endif

public enum NativeHostPluginError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case deadlineExceeded
    case malformedResponse(String)
    case rateLimited(retryNanoseconds: UInt64)
    case storageLimit
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Native session operation was cancelled"
        case .deadlineExceeded: "Native session operation exceeded its deadline"
        case .malformedResponse(let detail): "Native host returned a malformed response: \(detail)"
        case .rateLimited: "Native host rate limit remained active after bounded retries"
        case .storageLimit: "Native host session ledger reached its configured limit"
        case .sessionNotFound(let id): "Native host session was not found: \(id)"
        }
    }
}

public struct NativeTransportSession: Sendable, Equatable {
    public var providerSessionID: String
    public var model: String?

    public init(providerSessionID: String, model: String? = nil) {
        self.providerSessionID = providerSessionID
        self.model = model
    }
}

public struct NativeBootstrapRequest: Sendable {
    public var operationID: String
    public var projectID: String
    public var successorSessionID: String
    public var providerSessionID: String
    public var handoffID: String
    public var handoffSHA256: String
    public var canonicalHandoff: Data
    public var deadline: ContinuousClock.Instant
}

public struct NativeBootstrapResponse: Sendable {
    public var chunks: [Data]
    public var inputTokens: Int
    public var outputTokens: Int

    public init(chunks: [Data], inputTokens: Int = 0, outputTokens: Int = 0) {
        self.chunks = chunks
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public protocol NativeSessionTransport: Sendable {
    func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession
    func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse
    func cancel(operationID: String, providerSessionID: String?) async
}

public actor LocalLogicalSessionTransport: NativeSessionTransport {
    public static let maximumSessions = 4096
    public static let maximumCancelledOperations = 256
    private var sessions: [String: NativeTransportSession] = [:]
    private var cancelled: Set<String> = []

    public init() {}

    public func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession {
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = sessions[request.idempotencyKey] { return existing }
        if sessions.count >= Self.maximumSessions, let oldest = sessions.keys.sorted().first {
            sessions.removeValue(forKey: oldest)
        }
        let digest = JSONSupport.sha256Hex(request.idempotencyKey)
        let session = NativeTransportSession(
            providerSessionID: "native-\(digest.prefix(24))", model: "forge-logical-session"
        )
        sessions[request.idempotencyKey] = session
        return session
    }

    public func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse {
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        guard ContinuousClock.now < request.deadline else { throw NativeHostPluginError.deadlineExceeded }
        let acknowledgement: [String: Any] = [
            "handoff_id": request.handoffID,
            "successor_session_id": request.successorSessionID,
        ]
        return NativeBootstrapResponse(
            chunks: [try JSONSupport.data(from: acknowledgement)],
            inputTokens: Int(ceil(Double(request.canonicalHandoff.count) / 3.5)), outputTokens: 16
        )
    }

    public func cancel(operationID: String, providerSessionID: String?) async {
        if cancelled.count >= Self.maximumCancelledOperations, let oldest = cancelled.sorted().first {
            cancelled.remove(oldest)
        }
        cancelled.insert(operationID)
    }
}

private enum NativeSessionStatus: String, Codable {
    case creating, created, bootstrapping, acknowledged, cancelled
}

private struct NativeSessionRecord: Codable, Sendable {
    var sessionID: String
    var providerSessionID: String?
    var model: String?
    var operationID: String
    var projectID: String
    var predecessorSessionID: String
    var idempotencyKey: String
    var status: NativeSessionStatus
    var handoffID: String?
    var handoffSHA256: String?
    var inputTokens: Int
    var outputTokens: Int
    var createdAt: String
    var updatedAt: String
}

private struct NativeSessionLedger: Codable {
    var schemaVersion: Int = 1
    var records: [NativeSessionRecord] = []
}

public actor ForgeNativeSessionHostAdapter: SessionHostAdapter {
    public nonisolated let identifier = ForgeNativeSessionHostPlugin.identifier
    public nonisolated let version = ForgeNativeSessionHostPlugin.version

    public static let maximumRecords = 4096
    public static let maximumResponseChunks = 256
    public static let maximumChunkBytes = 16 * 1024
    public static let maximumResponseBytes = 256 * 1024
    public static let maximumRetries = 3

    private let ledgerURL: URL
    private let transport: any NativeSessionTransport
    private var ledger: NativeSessionLedger
    private var cancelledOperations: Set<String> = []

    public init(storageDirectory: URL, transport: any NativeSessionTransport) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        self.ledgerURL = storageDirectory.appendingPathComponent("native-session-ledger.json")
        self.transport = transport
        self.ledger = try Self.loadLedger(from: ledgerURL)
    }

    public func capabilities() async throws -> HostCapabilities {
        ForgeNativeSessionHostPlugin.manifest.capabilities
    }

    public func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        if cancelledOperations.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = record(idempotencyKey: request.idempotencyKey),
           let providerID = existing.providerSessionID {
            return HostSession(id: existing.sessionID, providerSessionID: providerID, model: existing.model)
        }
        let logicalID: String
        if let pending = record(idempotencyKey: request.idempotencyKey) {
            guard pending.status != .cancelled else { throw NativeHostPluginError.cancelled }
            logicalID = pending.sessionID
        } else {
            try ensureCapacity()
            let now = ISO8601.string(from: Date())
            logicalID = UUID().uuidString.lowercased()
            ledger.records.append(NativeSessionRecord(
                sessionID: logicalID, providerSessionID: nil, model: nil,
                operationID: request.operationID, projectID: request.projectID,
                predecessorSessionID: request.predecessorSessionID,
                idempotencyKey: request.idempotencyKey, status: .creating,
                handoffID: nil, handoffSHA256: nil, inputTokens: 0, outputTokens: 0,
                createdAt: now, updatedAt: now
            ))
            try persist()
        }

        var lastRateLimit: NativeHostPluginError?
        for attempt in 0..<Self.maximumRetries {
            do {
                let provider = try await transport.createSession(
                    request: request, deadline: ContinuousClock.now.advanced(by: .seconds(10))
                )
                if cancelledOperations.contains(request.operationID) {
                    await transport.cancel(
                        operationID: request.operationID, providerSessionID: provider.providerSessionID
                    )
                    throw NativeHostPluginError.cancelled
                }
                try validateIdentifier(provider.providerSessionID, field: "provider_session_id")
                guard let index = index(idempotencyKey: request.idempotencyKey) else {
                    throw NativeHostPluginError.sessionNotFound(logicalID)
                }
                ledger.records[index].providerSessionID = provider.providerSessionID
                ledger.records[index].model = provider.model.map { String($0.prefix(256)) }
                ledger.records[index].status = .created
                ledger.records[index].updatedAt = ISO8601.string(from: Date())
                try persist()
                return HostSession(
                    id: logicalID, providerSessionID: provider.providerSessionID,
                    model: ledger.records[index].model
                )
            } catch let error as NativeHostPluginError {
                guard case .rateLimited(let delay) = error, attempt + 1 < Self.maximumRetries else {
                    throw error
                }
                lastRateLimit = error
                if delay > 0 { try await Task.sleep(nanoseconds: min(delay, 1_000_000_000)) }
            }
        }
        throw lastRateLimit ?? NativeHostPluginError.rateLimited(retryNanoseconds: 0)
    }

    public func session(forIdempotencyKey key: String) async throws -> HostSession? {
        guard let existing = record(idempotencyKey: key),
              let providerID = existing.providerSessionID,
              existing.status != .cancelled else { return nil }
        return HostSession(id: existing.sessionID, providerSessionID: providerID, model: existing.model)
    }

    public func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        let validated = try handoff.validated()
        let canonical = try JSONSupport.data(from: validated.asDictionary())
        guard canonical.count <= ContinuityHandoff.maximumEncodedBytes else {
            throw NativeHostPluginError.malformedResponse("handoff exceeds contract bound")
        }
        guard let index = index(sessionID: session.id),
              let providerID = ledger.records[index].providerSessionID else {
            throw NativeHostPluginError.sessionNotFound(session.id)
        }
        if ledger.records[index].status == .acknowledged,
           ledger.records[index].handoffID == validated.handoffID { return }
        ledger.records[index].status = .bootstrapping
        ledger.records[index].handoffID = validated.handoffID
        ledger.records[index].handoffSHA256 = validated.contentSHA256
        ledger.records[index].updatedAt = ISO8601.string(from: Date())
        try persist()

        let response = try await transport.bootstrap(NativeBootstrapRequest(
            operationID: ledger.records[index].operationID,
            projectID: ledger.records[index].projectID,
            successorSessionID: session.id,
            providerSessionID: providerID,
            handoffID: validated.handoffID,
            handoffSHA256: validated.contentSHA256,
            canonicalHandoff: canonical,
            deadline: ContinuousClock.now.advanced(by: .seconds(10))
        ))
        let acknowledgement = try decodeBoundedAcknowledgement(response.chunks)
        guard acknowledgement["handoff_id"] as? String == validated.handoffID,
              acknowledgement["successor_session_id"] as? String == session.id else {
            throw NativeHostPluginError.malformedResponse("acknowledgment identity mismatch")
        }
        guard response.inputTokens >= 0, response.outputTokens >= 0 else {
            throw NativeHostPluginError.malformedResponse("negative usage")
        }
        ledger.records[index].status = .acknowledged
        ledger.records[index].inputTokens = response.inputTokens
        ledger.records[index].outputTokens = response.outputTokens
        ledger.records[index].updatedAt = ISO8601.string(from: Date())
        try persist()
    }

    public func awaitAcknowledgement(
        session: HostSession, handoffID: String, timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        guard let existing = record(sessionID: session.id),
              existing.status == .acknowledged,
              existing.handoffID == handoffID else {
            throw NativeHostPluginError.deadlineExceeded
        }
        return HandoffAcknowledgement(
            handoffID: handoffID, successorSessionID: session.id, adapterID: identifier
        )
    }

    public func cancel(operationID: String) async {
        if cancelledOperations.count >= 256, let oldest = cancelledOperations.first {
            cancelledOperations.remove(oldest)
        }
        cancelledOperations.insert(operationID)
        let providerID = ledger.records.first { $0.operationID == operationID }?.providerSessionID
        if let index = ledger.records.firstIndex(where: { $0.operationID == operationID }) {
            ledger.records[index].status = .cancelled
            ledger.records[index].updatedAt = ISO8601.string(from: Date())
            try? persist()
        }
        await transport.cancel(operationID: operationID, providerSessionID: providerID)
    }

    public func health() -> [String: Any] {
        [
            "ok": true, "adapter_id": identifier, "version": version,
            "records": ledger.records.count, "maximum_records": Self.maximumRecords,
            "response_bytes": Self.maximumResponseBytes,
            "ledger": ledgerURL.path,
        ]
    }

    private func decodeBoundedAcknowledgement(_ chunks: [Data]) throws -> [String: Any] {
        guard !chunks.isEmpty, chunks.count <= Self.maximumResponseChunks else {
            throw NativeHostPluginError.malformedResponse("response chunk count is outside limits")
        }
        var payload = Data()
        payload.reserveCapacity(min(Self.maximumResponseBytes, chunks.reduce(0) { $0 + $1.count }))
        for chunk in chunks {
            guard chunk.count <= Self.maximumChunkBytes,
                  payload.count + chunk.count <= Self.maximumResponseBytes else {
                throw NativeHostPluginError.malformedResponse("response exceeds streaming limits")
            }
            payload.append(chunk)
        }
        do { return try JSONSupport.object(from: payload) }
        catch { throw NativeHostPluginError.malformedResponse("acknowledgment is not JSON") }
    }

    private func record(idempotencyKey: String) -> NativeSessionRecord? {
        ledger.records.first { $0.idempotencyKey == idempotencyKey }
    }

    private func record(sessionID: String) -> NativeSessionRecord? {
        ledger.records.first { $0.sessionID == sessionID }
    }

    private func index(idempotencyKey: String) -> Int? {
        ledger.records.firstIndex { $0.idempotencyKey == idempotencyKey }
    }

    private func index(sessionID: String) -> Int? {
        ledger.records.firstIndex { $0.sessionID == sessionID }
    }

    private func ensureCapacity() throws {
        guard ledger.records.count >= Self.maximumRecords else { return }
        ledger.records.removeAll { $0.status == .acknowledged || $0.status == .cancelled }
        ledger.records = Array(ledger.records.suffix(Self.maximumRecords - 1))
        guard ledger.records.count < Self.maximumRecords else { throw NativeHostPluginError.storageLimit }
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw NativeHostPluginError.malformedResponse("invalid \(field)")
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        try data.write(
            to: ledgerURL,
            options: Data.WritingOptions([.atomic, .completeFileProtectionUnlessOpen])
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }

    private static func loadLedger(from url: URL) throws -> NativeSessionLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return NativeSessionLedger() }
        let value = try JSONDecoder().decode(NativeSessionLedger.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.records.count <= maximumRecords else {
            throw NativeHostPluginError.malformedResponse("unsupported or oversized ledger")
        }
        return value
    }
}

public enum ForgeNativeSessionHostPlugin {
    public static let identifier = "forge.native-session-host"
    public static let version = "1.0.0"
    public static let manifest = HostPluginManifest(
        identifier: identifier, version: version, minimumContractVersion: 1,
        hostType: "forge-native-logical-session",
        capabilities: HostCapabilities(
            create: true, bootstrap: true, usageReporting: true,
            resume: true, idempotency: true, queryByIdempotencyKey: true
        ),
        configurationKeys: ["storage_directory", "provider_transport"],
        privacyRequirements: [
            "no complete transcript persistence", "redacted diagnostics",
            "provider secrets remain in configured secure transport",
        ],
        migrationVersion: 1
    )

    public static func register(in registry: HostAdapterRegistry = .shared) {
        registry.register(manifest: manifest) { storageDirectory in
            try ForgeNativeSessionHostAdapter(
                storageDirectory: storageDirectory,
                transport: LocalLogicalSessionTransport()
            )
        }
    }
}

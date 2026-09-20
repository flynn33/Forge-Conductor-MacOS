// StjornarvaldObservationClient.swift
// What: Spools process observations before best-effort manager submission.
// How: One actor-owned drain task sends bounded owner-only outbox files in order.
// Why: Manager outage must never change or delay the development operation observed.

import Foundation

public protocol StjornarvaldObservationTransport: Sendable {
    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch
}

public actor StjornarvaldObservationClient: PolicyObservationSubmitting {
    public static let maximumOutboxItems = 10_000
    public static let maximumBatchCount = 64

    private struct Envelope: Codable, Sendable {
        let processID: String
        let bootID: String
        let observation: DevelopmentObservation
    }

    private let transport: any StjornarvaldObservationTransport
    private let outboxDirectory: URL
    private let processID: String
    private let bootID: String
    private let diagnostics: @Sendable (String) -> Void
    private var drainTask: Task<Void, Never>?

    public init(
        transport: any StjornarvaldObservationTransport,
        outboxDirectory: URL,
        processID: String,
        bootID: String,
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.outboxDirectory = outboxDirectory.standardizedFileURL
        self.processID = String(processID.prefix(256))
        self.bootID = String(bootID.prefix(256))
        self.diagnostics = diagnostics
    }

    deinit { drainTask?.cancel() }

    public func submit(_ observation: DevelopmentObservation) {
        do {
            try persist(observation)
            startDrainIfNeeded()
        } catch {
            diagnostics("stjornarvald client observation could not be retained: \(error.localizedDescription)")
        }
    }

    public func resume() {
        startDrainIfNeeded()
    }

    public func pendingCount() -> Int {
        boundedFiles(limit: Self.maximumOutboxItems).count
    }

    public func shutdown() async {
        let current = drainTask
        drainTask = nil
        current?.cancel()
        _ = await current?.result
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !boundedFiles(limit: 1).isEmpty else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        defer { drainTask = nil }
        while let file = boundedFiles(limit: Self.maximumOutboxItems).first {
            if Task.isCancelled { return }
            do {
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard data.count <= StjornarvaldObservationRepository.maximumObservationBytes else {
                    throw StjornarvaldObservationError.invalidObservation(
                        "client outbox item exceeds observation byte bound"
                    )
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let envelope = try decoder.decode(Envelope.self, from: data)
                let batch = try await transport.submit(
                    processID: envelope.processID,
                    bootID: envelope.bootID,
                    observations: [envelope.observation]
                )
                guard batch.receipts.count == 1,
                      let receipt = batch.receipts.first,
                      receipt.observationID == envelope.observation.id else {
                    throw StjornarvaldObservationError.conflict(
                        "manager returned a mismatched observation receipt"
                    )
                }
                if receipt.state == .deferred {
                    diagnostics("stjornarvald client drain deferred by manager")
                    return
                }
                if receipt.state == .rejected {
                    diagnostics("stjornarvald client discarded a manager-rejected observation")
                }
                try FileManager.default.removeItem(at: file)
            } catch is CancellationError {
                return
            } catch {
                diagnostics("stjornarvald client drain deferred: \(error.localizedDescription)")
                return
            }
        }
    }

    private func persist(_ observation: DevelopmentObservation) throws {
        guard !processID.isEmpty, !bootID.isEmpty else {
            throw StjornarvaldObservationError.invalidObservation(
                "client process identity is unavailable"
            )
        }
        let manager = FileManager.default
        try manager.createDirectory(
            at: outboxDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxDirectory.path)
        let identitySuffix = "-\(observation.id.uuidString.lowercased()).json"
        if let existing = boundedFiles(limit: Self.maximumOutboxItems).first(where: {
            $0.lastPathComponent.hasSuffix(identitySuffix)
        }) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(
                Envelope.self,
                from: Data(contentsOf: existing, options: [.mappedIfSafe])
            )
            guard stored.observation == observation,
                  stored.processID == processID,
                  stored.bootID == bootID else {
                throw StjornarvaldObservationError.conflict(
                    "client observation identity changed"
                )
            }
            return
        }
        let sequence = try nextOutboxSequence()
        let file = outboxDirectory.appendingPathComponent(
            String(format: "%020llu", sequence) + identitySuffix
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(
            processID: processID,
            bootID: bootID,
            observation: observation
        ))
        guard data.count <= StjornarvaldObservationRepository.maximumObservationBytes else {
            throw StjornarvaldObservationError.invalidObservation(
                "client observation exceeds byte bound"
            )
        }
        guard boundedFiles(limit: Self.maximumOutboxItems).count < Self.maximumOutboxItems else {
            throw StjornarvaldObservationError.unavailable("client observation outbox is full")
        }
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func nextOutboxSequence() throws -> UInt64 {
        let wallClock = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        let latest = boundedFiles(limit: Self.maximumOutboxItems).compactMap { url -> UInt64? in
            guard let separator = url.lastPathComponent.firstIndex(of: "-") else { return nil }
            return UInt64(url.lastPathComponent[..<separator])
        }.max() ?? 0
        guard latest < UInt64.max else {
            throw StjornarvaldObservationError.unavailable(
                "client observation outbox sequence is exhausted"
            )
        }
        return max(wallClock, latest + 1)
    }

    private func boundedFiles(limit: Int) -> [URL] {
        guard let values = try? FileManager.default.contentsOfDirectory(
            at: outboxDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Array(values.filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.prefix(limit))
    }
}

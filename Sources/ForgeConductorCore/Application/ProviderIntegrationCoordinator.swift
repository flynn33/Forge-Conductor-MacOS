// ProviderIntegrationCoordinator.swift
// What: Owns mutually exclusive provider selection and desktop integration operations.
// How: An actor serializes compare-and-swap mutations around an owner-only bounded ledger.
// Why: Plugin provisioning must finish before selection changes and must recover safely after interruption.

import Foundation

public actor ProviderIntegrationCoordinator {
    private static let ledgerSchemaVersion = 1

    private let ledgerURL: URL
    private let adapters: [ProviderIntegrationID: any ProviderIntegrationAdapting]
    private let now: @Sendable () -> Date
    private var ledger: ProviderIntegrationLedger
    private var operationTasks: [String: Task<Void, Never>] = [:]
    private var cancellationRequested: Set<String> = []

    public init(
        paths: AppPaths,
        adapters adapterList: [any ProviderIntegrationAdapting],
        defaultSelectedProviderID: ProviderIntegrationID? = .lmStudio,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        var adapters: [ProviderIntegrationID: any ProviderIntegrationAdapting] = [:]
        for adapter in adapterList {
            guard adapters[adapter.providerID] == nil else {
                throw ProviderIntegrationError.invalidRequest(
                    field: "adapters",
                    reason: "duplicate_\(adapter.providerID.rawValue)"
                )
            }
            adapters[adapter.providerID] = adapter
        }
        if let defaultSelectedProviderID,
           !Self.isSelectable(defaultSelectedProviderID) {
            throw ProviderIntegrationError.providerNotSelectable(
                providerID: defaultSelectedProviderID
            )
        }

        self.ledgerURL = paths.providerIntegrationsLedger
        self.adapters = adapters
        self.now = now
        self.ledger = try Self.loadAndReconcile(
            from: paths.providerIntegrationsLedger,
            defaultSelectedProviderID: defaultSelectedProviderID,
            timestamp: ISO8601.string(from: now())
        )
    }

    deinit {
        for task in operationTasks.values { task.cancel() }
    }

    public func snapshot() -> ProviderIntegrationsSnapshot {
        makeSnapshot(from: ledger)
    }

    /// Performs a read-only live inspection. The durable snapshot intentionally
    /// does not claim that a prior receipt proves the desktop host is connected.
    public func inspect(
        providerID: ProviderIntegrationID
    ) async throws -> ProviderIntegrationInspection {
        guard Self.isSelectable(providerID) else {
            throw ProviderIntegrationError.providerNotSelectable(
                providerID: providerID
            )
        }
        guard let adapter = adapters[providerID] else {
            throw ProviderIntegrationError.adapterUnavailable(
                providerID: providerID
            )
        }
        let inspection = try await adapter.inspect(
            operationID: "inspection-\(UUID().uuidString.lowercased())"
        )
        try validate(inspection.receipt, for: providerID)
        return inspection
    }

    public func operation(
        operationID: String
    ) throws -> ProviderIntegrationOperationSnapshot {
        try ProviderIntegrationContract.validateText(
            operationID,
            field: "operation_id",
            maximumBytes: ProviderIntegrationContract.maximumOperationIDBytes
        )
        guard let operation = findOperation(operationID, in: ledger) else {
            throw ProviderIntegrationError.operationNotFound(operationID: operationID)
        }
        return operation
    }

    /// Selects a provider, or selects none when `providerID` is nil. Acceptance
    /// is durable; adapter work continues asynchronously.
    public func select(
        _ request: ProviderSelectionRequest
    ) throws -> ProviderIntegrationOperationSnapshot {
        let kind: ProviderIntegrationOperationKind =
            request.providerID == nil ? .deactivate : .activate
        let accepted = try accept(
            kind: kind,
            providerID: request.providerID,
            expectedRevision: request.expectedRevision,
            idempotencyKey: request.idempotencyKey
        )
        guard !accepted.replayed else { return accepted.operation }

        let operationID = accepted.operation.operationID
        let providerID = request.providerID
        operationTasks[operationID] = Task { [weak self] in
            guard let self else { return }
            await self.executeSelection(
                operationID: operationID,
                providerID: providerID
            )
        }
        return accepted.operation
    }

    public func repair(
        _ request: ProviderIntegrationMutationRequest
    ) throws -> ProviderIntegrationOperationSnapshot {
        let accepted = try accept(
            kind: .repair,
            providerID: request.providerID,
            expectedRevision: request.expectedRevision,
            idempotencyKey: request.idempotencyKey
        )
        guard !accepted.replayed else { return accepted.operation }

        let operationID = accepted.operation.operationID
        let providerID = request.providerID
        operationTasks[operationID] = Task { [weak self] in
            guard let self else { return }
            await self.executeRepair(
                operationID: operationID,
                providerID: providerID
            )
        }
        return accepted.operation
    }

    public func remove(
        _ request: ProviderIntegrationMutationRequest
    ) throws -> ProviderIntegrationOperationSnapshot {
        if ledger.selectedProviderID == request.providerID {
            throw ProviderIntegrationError.selectedProviderCannotBeRemoved(
                providerID: request.providerID
            )
        }
        let accepted = try accept(
            kind: .remove,
            providerID: request.providerID,
            expectedRevision: request.expectedRevision,
            idempotencyKey: request.idempotencyKey
        )
        guard !accepted.replayed else { return accepted.operation }

        let operationID = accepted.operation.operationID
        let providerID = request.providerID
        operationTasks[operationID] = Task { [weak self] in
            guard let self else { return }
            await self.executeRemoval(
                operationID: operationID,
                providerID: providerID
            )
        }
        return accepted.operation
    }

    public func cancel(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try ProviderIntegrationContract.validateText(
            operationID,
            field: "operation_id",
            maximumBytes: ProviderIntegrationContract.maximumOperationIDBytes
        )
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID else {
            if let existing = findOperation(operationID, in: ledger) {
                if existing.phase == .cancelled { return existing }
                throw ProviderIntegrationError.operationNotCancellable(
                    operationID: operationID
                )
            }
            throw ProviderIntegrationError.operationNotFound(operationID: operationID)
        }
        guard !current.phase.isTerminal else {
            throw ProviderIntegrationError.operationNotCancellable(
                operationID: operationID
            )
        }

        cancellationRequested.insert(operationID)
        defer { cancellationRequested.remove(operationID) }
        let operationTask = operationTasks[operationID]
        operationTask?.cancel()
        if let providerID = current.providerID,
           let adapter = adapters[providerID] {
            await adapter.cancel(operationID: operationID)
        }
        // Synchronous host installers cannot always stop between filesystem or CLI
        // calls. Do not publish a terminal cancellation until their task has fully
        // drained and can no longer mutate integration state.
        if let operationTask { await operationTask.value }
        try finishCancelled(operationID: operationID)
        return try operation(operationID: operationID)
    }

    /// Waits only for an operation already accepted by this coordinator. This
    /// is intended for tests and bounded manager polling bridges, not UI waits.
    public func waitForOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        if let task = operationTasks[operationID] { await task.value }
        return try operation(operationID: operationID)
    }

    private func accept(
        kind: ProviderIntegrationOperationKind,
        providerID: ProviderIntegrationID?,
        expectedRevision: String,
        idempotencyKey: String
    ) throws -> (operation: ProviderIntegrationOperationSnapshot, replayed: Bool) {
        let idempotencyHash = JSONSupport.sha256Hex(idempotencyKey)
        let intentHash = Self.intentHash(
            kind: kind,
            providerID: providerID,
            expectedRevision: expectedRevision
        )
        if let existing = allOperations(in: ledger).first(where: {
            $0.idempotencyKeySHA256 == idempotencyHash
        }) {
            guard existing.intentSHA256 == intentHash else {
                throw ProviderIntegrationError.idempotencyConflict
            }
            return (existing, true)
        }

        if let current = ledger.currentOperation?.operation {
            throw ProviderIntegrationError.operationBusy(
                operationID: current.operationID
            )
        }
        guard expectedRevision == ledger.selectionRevision else {
            throw ProviderIntegrationError.revisionConflict(
                expected: expectedRevision,
                actual: ledger.selectionRevision
            )
        }
        if let providerID {
            let isKnownProvider = ProviderIntegrationDescriptor.supported.contains {
                $0.id == providerID
            }
            guard kind == .remove ? isKnownProvider : Self.isSelectable(providerID) else {
                throw ProviderIntegrationError.providerNotSelectable(
                    providerID: providerID
                )
            }
            guard adapters[providerID] != nil else {
                throw ProviderIntegrationError.adapterUnavailable(
                    providerID: providerID
                )
            }
        }

        let timestamp = ISO8601.string(from: now())
        let operation = ProviderIntegrationOperationSnapshot(
            operationID: UUID().uuidString.lowercased(),
            kind: kind,
            providerID: providerID,
            phase: .accepted,
            expectedRevision: expectedRevision,
            idempotencyKeySHA256: idempotencyHash,
            intentSHA256: intentHash,
            detail: "Provider operation accepted.",
            acceptedAt: timestamp,
            updatedAt: timestamp
        )
        var updated = ledger
        updated.currentOperation = StoredProviderIntegrationOperation(
            operation: operation
        )
        try commit(updated)
        return (operation, false)
    }

    private func executeSelection(
        operationID: String,
        providerID: ProviderIntegrationID?
    ) async {
        defer { operationTasks[operationID] = nil }
        do {
            try Task.checkCancellation()
            if providerID == nil {
                try completeSelection(
                    operationID: operationID,
                    selectedProviderID: nil,
                    receipt: nil,
                    detail: "No provider is selected. Installed integrations were retained.",
                    phase: .completed
                )
                return
            }
            guard let providerID, let adapter = adapters[providerID] else {
                throw ProviderIntegrationError.adapterUnavailable(
                    providerID: providerID ?? .lmStudio
                )
            }

            guard try updateCurrent(
                operationID: operationID,
                phase: .inspectingHost,
                detail: "Inspecting the provider host and Forge-owned integration."
            ) else { return }
            let inspection = try await adapter.inspect(operationID: operationID)
            try Task.checkCancellation()
            try validate(inspection.receipt, for: providerID)
            guard isCurrentAndCancellable(operationID) else { return }

            switch inspection.state {
            case .awaitingUserAction:
                try finishAwaitingUserAction(
                    operationID: operationID,
                    receipt: inspection.receipt,
                    detail: inspection.detail
                )
            case .ready:
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .activatingHost,
                    detail: inspection.detail
                ) else { return }
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .verifyingConfiguration,
                    detail: "The installed integration passed verification."
                ) else { return }
                try completeSelection(
                    operationID: operationID,
                    selectedProviderID: providerID,
                    receipt: inspection.receipt,
                    detail: "\(providerID.rawValue) is selected.",
                    phase: .active
                )
            case .requiresProvisioning:
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .verifyingBridge,
                    detail: "Verifying the native Forge bridge."
                ) else { return }
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .staging,
                    detail: "Staging Forge-owned provider integration artifacts."
                ) else { return }
                try Task.checkCancellation()
                let result = try await adapter.provision(.init(
                    operationID: operationID,
                    kind: .activate,
                    existingReceipt: existingReceipt(for: providerID)
                ))
                try Task.checkCancellation()
                try validate(result.receipt, for: providerID)
                guard isCurrentAndCancellable(operationID) else { return }
                if result.state == .awaitingUserAction {
                    try finishAwaitingUserAction(
                        operationID: operationID,
                        receipt: result.receipt,
                        detail: result.detail
                    )
                    return
                }
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .committing,
                    detail: "Committing Forge-owned integration artifacts."
                ) else { return }
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .activatingHost,
                    detail: result.detail
                ) else { return }
                guard try updateCurrent(
                    operationID: operationID,
                    phase: .verifyingConfiguration,
                    detail: "The committed integration passed verification."
                ) else { return }
                try completeSelection(
                    operationID: operationID,
                    selectedProviderID: providerID,
                    receipt: result.receipt,
                    detail: "\(providerID.rawValue) is selected.",
                    phase: .active
                )
            }
        } catch is CancellationError {
            if !cancellationRequested.contains(operationID) {
                try? finishCancelled(operationID: operationID)
            }
        } catch {
            if !cancellationRequested.contains(operationID) {
                try? finishFailure(operationID: operationID, error: error)
            }
        }
    }

    private func executeRepair(
        operationID: String,
        providerID: ProviderIntegrationID
    ) async {
        defer { operationTasks[operationID] = nil }
        do {
            guard let adapter = adapters[providerID] else {
                throw ProviderIntegrationError.adapterUnavailable(providerID: providerID)
            }
            guard try updateCurrent(
                operationID: operationID,
                phase: .inspectingHost,
                detail: "Inspecting the provider integration before repair."
            ) else { return }
            let inspection = try await adapter.inspect(operationID: operationID)
            try Task.checkCancellation()
            try validate(inspection.receipt, for: providerID)
            guard isCurrentAndCancellable(operationID) else { return }
            guard try updateCurrent(
                operationID: operationID,
                phase: .verifyingBridge,
                detail: "Verifying the native Forge bridge before repair."
            ) else { return }
            guard try updateCurrent(
                operationID: operationID,
                phase: .staging,
                detail: "Staging replacement Forge-owned artifacts."
            ) else { return }
            try Task.checkCancellation()
            let result = try await adapter.repair(.init(
                operationID: operationID,
                kind: .repair,
                existingReceipt: existingReceipt(for: providerID)
            ))
            try Task.checkCancellation()
            try validate(result.receipt, for: providerID)
            guard isCurrentAndCancellable(operationID) else { return }
            if result.state == .awaitingUserAction {
                try finishAwaitingUserAction(
                    operationID: operationID,
                    receipt: result.receipt,
                    detail: result.detail
                )
                return
            }
            guard try updateCurrent(
                operationID: operationID,
                phase: .committing,
                detail: "Committing repaired Forge-owned artifacts."
            ) else { return }
            try finishWithoutSelectionChange(
                operationID: operationID,
                phase: .completed,
                receipt: result.receipt,
                removeReceiptFor: nil,
                detail: result.detail,
                advanceSelectionRevision: ledger.selectedProviderID == providerID
            )
        } catch is CancellationError {
            if !cancellationRequested.contains(operationID) {
                try? finishCancelled(operationID: operationID)
            }
        } catch {
            if !cancellationRequested.contains(operationID) {
                try? finishFailure(operationID: operationID, error: error)
            }
        }
    }

    private func executeRemoval(
        operationID: String,
        providerID: ProviderIntegrationID
    ) async {
        defer { operationTasks[operationID] = nil }
        do {
            guard let adapter = adapters[providerID] else {
                throw ProviderIntegrationError.adapterUnavailable(providerID: providerID)
            }
            guard try updateCurrent(
                operationID: operationID,
                phase: .inspectingHost,
                detail: "Inspecting Forge-owned artifacts before removal."
            ) else { return }
            _ = try await adapter.inspect(operationID: operationID)
            try Task.checkCancellation()
            guard isCurrentAndCancellable(operationID) else { return }
            guard try updateCurrent(
                operationID: operationID,
                phase: .staging,
                detail: "Preparing selective removal of Forge-owned artifacts."
            ) else { return }
            try Task.checkCancellation()
            let removal = try await adapter.remove(.init(
                operationID: operationID,
                kind: .remove,
                existingReceipt: existingReceipt(for: providerID)
            ))
            try Task.checkCancellation()
            guard isCurrentAndCancellable(operationID) else { return }
            if removal.state == .awaitingUserAction {
                try finishAwaitingUserAction(
                    operationID: operationID,
                    receipt: existingReceipt(for: providerID),
                    detail: removal.detail
                )
                return
            }
            try finishWithoutSelectionChange(
                operationID: operationID,
                phase: .removed,
                receipt: nil,
                removeReceiptFor: providerID,
                detail: removal.detail
            )
        } catch is CancellationError {
            if !cancellationRequested.contains(operationID) {
                try? finishCancelled(operationID: operationID)
            }
        } catch {
            if !cancellationRequested.contains(operationID) {
                try? finishFailure(operationID: operationID, error: error)
            }
        }
    }

    @discardableResult
    private func updateCurrent(
        operationID: String,
        phase: ProviderIntegrationOperationPhase,
        detail: String,
        errorCode: String? = nil,
        terminal: Bool = false
    ) throws -> Bool {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              !current.phase.isTerminal else { return false }
        let timestamp = ISO8601.string(from: now())
        let updatedOperation = replacing(
            current,
            phase: phase,
            resultingRevision: current.resultingRevision,
            detail: Self.bounded(detail),
            errorCode: errorCode,
            updatedAt: timestamp,
            completedAt: terminal ? timestamp : nil
        )
        var updated = ledger
        updated.currentOperation = .init(operation: updatedOperation)
        try commit(updated)
        return true
    }

    private func completeSelection(
        operationID: String,
        selectedProviderID: ProviderIntegrationID?,
        receipt: ProviderIntegrationReceipt?,
        detail: String,
        phase: ProviderIntegrationOperationPhase
    ) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              !current.phase.isTerminal else { return }
        if let selectedProviderID {
            try validate(receipt, for: selectedProviderID)
        }
        let timestamp = ISO8601.string(from: now())
        let newRevision = Self.newRevision()
        let terminal = replacing(
            current,
            phase: phase,
            resultingRevision: newRevision,
            detail: Self.bounded(detail),
            errorCode: nil,
            updatedAt: timestamp,
            completedAt: timestamp
        )
        var updated = ledger
        updated.selectionRevision = newRevision
        updated.selectedProviderID = selectedProviderID
        if let receipt { Self.upsert(receipt, in: &updated.receipts) }
        Self.archive(terminal, in: &updated)
        try commit(updated)
    }

    private func finishWithoutSelectionChange(
        operationID: String,
        phase: ProviderIntegrationOperationPhase,
        receipt: ProviderIntegrationReceipt?,
        removeReceiptFor providerID: ProviderIntegrationID?,
        detail: String,
        advanceSelectionRevision: Bool = false
    ) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              !current.phase.isTerminal else { return }
        if let receipt { try validate(receipt, for: current.providerID) }
        let timestamp = ISO8601.string(from: now())
        let resultingRevision = advanceSelectionRevision
            ? Self.newRevision()
            : ledger.selectionRevision
        let terminal = replacing(
            current,
            phase: phase,
            resultingRevision: resultingRevision,
            detail: Self.bounded(detail),
            errorCode: nil,
            updatedAt: timestamp,
            completedAt: timestamp
        )
        var updated = ledger
        updated.selectionRevision = resultingRevision
        if let receipt { Self.upsert(receipt, in: &updated.receipts) }
        if let providerID {
            updated.receipts.removeAll { $0.providerID == providerID }
        }
        Self.archive(terminal, in: &updated)
        try commit(updated)
    }

    private func finishAwaitingUserAction(
        operationID: String,
        receipt: ProviderIntegrationReceipt?,
        detail: String
    ) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              !current.phase.isTerminal else { return }
        if let receipt { try validate(receipt, for: current.providerID) }
        let timestamp = ISO8601.string(from: now())
        let terminal = replacing(
            current,
            phase: .awaitingUserAction,
            resultingRevision: nil,
            detail: Self.bounded(detail),
            errorCode: "user_action_required",
            updatedAt: timestamp,
            completedAt: timestamp
        )
        var updated = ledger
        if let receipt { Self.upsert(receipt, in: &updated.receipts) }
        Self.archive(terminal, in: &updated)
        try commit(updated)
    }

    private func finishFailure(operationID: String, error: Error) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              !current.phase.isTerminal else { return }
        _ = try updateCurrent(
            operationID: operationID,
            phase: .rollingBack,
            detail: "Retaining the previously selected provider."
        )
        guard let rollingBack = ledger.currentOperation?.operation,
              rollingBack.operationID == operationID,
              !rollingBack.phase.isTerminal else { return }
        let timestamp = ISO8601.string(from: now())
        let terminal = replacing(
            rollingBack,
            phase: .failedRecoverable,
            resultingRevision: nil,
            detail: Self.bounded(error.localizedDescription),
            errorCode: "provider_integration_failed",
            updatedAt: timestamp,
            completedAt: timestamp
        )
        var updated = ledger
        Self.archive(terminal, in: &updated)
        try commit(updated)
    }

    private func finishCancelled(operationID: String) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID else { return }
        if current.phase == .cancelled {
            try archiveTerminalCurrent(operationID: operationID)
            return
        }
        guard !current.phase.isTerminal else { return }
        _ = try updateCurrent(
            operationID: operationID,
            phase: .cancelled,
            detail: "Cancellation completed after in-flight host work drained; the prior provider selection was retained.",
            errorCode: "cancelled",
            terminal: true
        )
        try archiveTerminalCurrent(operationID: operationID)
    }

    private func archiveTerminalCurrent(operationID: String) throws {
        guard let current = ledger.currentOperation?.operation,
              current.operationID == operationID,
              current.phase.isTerminal else { return }
        var updated = ledger
        Self.archive(current, in: &updated)
        try commit(updated)
    }

    private func isCurrentAndCancellable(_ operationID: String) -> Bool {
        guard let current = ledger.currentOperation?.operation else { return false }
        return current.operationID == operationID && !current.phase.isTerminal
    }

    private func existingReceipt(
        for providerID: ProviderIntegrationID
    ) -> ProviderIntegrationReceipt? {
        ledger.receipts.first { $0.providerID == providerID }
    }

    private func validate(
        _ receipt: ProviderIntegrationReceipt?,
        for providerID: ProviderIntegrationID?
    ) throws {
        guard let receipt else { return }
        guard receipt.providerID == providerID else {
            throw ProviderIntegrationError.invalidAdapterResult(
                reason: "receipt_provider_mismatch"
            )
        }
    }

    private func commit(_ updated: ProviderIntegrationLedger) throws {
        try Self.persist(updated, to: ledgerURL)
        ledger = updated
    }

    private func makeSnapshot(
        from ledger: ProviderIntegrationLedger
    ) -> ProviderIntegrationsSnapshot {
        let providers = ProviderIntegrationDescriptor.supported.map { descriptor in
            ProviderIntegrationProviderSnapshot(
                descriptor: descriptor,
                receipt: ledger.receipts.first { $0.providerID == descriptor.id }
            )
        }
        return ProviderIntegrationsSnapshot(
            selectionRevision: ledger.selectionRevision,
            selectedProviderID: ledger.selectedProviderID,
            providers: providers,
            currentOperation: ledger.currentOperation?.operation,
            recentOperations: ledger.recentOperations.map(\.operation)
        )
    }

    private func findOperation(
        _ operationID: String,
        in ledger: ProviderIntegrationLedger
    ) -> ProviderIntegrationOperationSnapshot? {
        allOperations(in: ledger).first { $0.operationID == operationID }
    }

    private func allOperations(
        in ledger: ProviderIntegrationLedger
    ) -> [ProviderIntegrationOperationSnapshot] {
        (ledger.currentOperation.map { [$0.operation] } ?? [])
            + ledger.recentOperations.map(\.operation)
    }

    private func replacing(
        _ operation: ProviderIntegrationOperationSnapshot,
        phase: ProviderIntegrationOperationPhase,
        resultingRevision: String?,
        detail: String?,
        errorCode: String?,
        updatedAt: String,
        completedAt: String?
    ) -> ProviderIntegrationOperationSnapshot {
        ProviderIntegrationOperationSnapshot(
            operationID: operation.operationID,
            kind: operation.kind,
            providerID: operation.providerID,
            phase: phase,
            expectedRevision: operation.expectedRevision,
            resultingRevision: resultingRevision,
            idempotencyKeySHA256: operation.idempotencyKeySHA256,
            intentSHA256: operation.intentSHA256,
            detail: detail,
            errorCode: errorCode,
            acceptedAt: operation.acceptedAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }

    private static func isSelectable(_ providerID: ProviderIntegrationID) -> Bool {
        ProviderIntegrationDescriptor.supported.first { $0.id == providerID }?.selectable == true
    }

    private static func intentHash(
        kind: ProviderIntegrationOperationKind,
        providerID: ProviderIntegrationID?,
        expectedRevision: String
    ) -> String {
        JSONSupport.sha256Hex(
            "\(kind.rawValue)\u{0}\(providerID?.rawValue ?? "none")\u{0}\(expectedRevision)"
        )
    }

    private static func newRevision() -> String {
        UUID().uuidString.lowercased()
    }

    private static func bounded(_ value: String) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= ProviderIntegrationContract.maximumDetailBytes else {
                break
            }
            result.append(character)
            byteCount += bytes
        }
        return result
    }

    private static func upsert(
        _ receipt: ProviderIntegrationReceipt,
        in receipts: inout [ProviderIntegrationReceipt]
    ) {
        receipts.removeAll { $0.providerID == receipt.providerID }
        receipts.append(receipt)
        receipts.sort { $0.providerID.rawValue < $1.providerID.rawValue }
    }

    private static func archive(
        _ operation: ProviderIntegrationOperationSnapshot,
        in ledger: inout ProviderIntegrationLedger
    ) {
        ledger.currentOperation = nil
        ledger.recentOperations.removeAll {
            $0.operation.operationID == operation.operationID
        }
        ledger.recentOperations.insert(
            StoredProviderIntegrationOperation(operation: operation),
            at: 0
        )
        if ledger.recentOperations.count > ProviderIntegrationContract.maximumRecentOperations {
            ledger.recentOperations = Array(
                ledger.recentOperations.prefix(
                    ProviderIntegrationContract.maximumRecentOperations
                )
            )
        }
    }

    private static func loadAndReconcile(
        from url: URL,
        defaultSelectedProviderID: ProviderIntegrationID?,
        timestamp: String
    ) throws -> ProviderIntegrationLedger {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            let initial = ProviderIntegrationLedger(
                schemaVersion: ledgerSchemaVersion,
                selectionRevision: newRevision(),
                selectedProviderID: defaultSelectedProviderID,
                currentOperation: nil,
                recentOperations: [],
                receipts: []
            )
            try persist(initial, to: url)
            return initial
        }

        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(
                from: url,
                maximumBytes: ProviderIntegrationContract.maximumLedgerBytes
            )
        } catch {
            throw ProviderIntegrationError.persistenceFailed(
                reason: bounded(String(describing: error))
            )
        }
        let decoded: ProviderIntegrationLedger
        do {
            decoded = try JSONDecoder().decode(ProviderIntegrationLedger.self, from: data)
            try validate(decoded)
        } catch let error as ProviderIntegrationError {
            throw error
        } catch {
            throw ProviderIntegrationError.ledgerCorrupt(
                reason: bounded(String(describing: error))
            )
        }

        var reconciled = decoded
        var requiresPersistence = false
        if let current = reconciled.currentOperation?.operation {
            let recovered: ProviderIntegrationOperationSnapshot
            if current.phase.isTerminal {
                recovered = current
            } else {
                recovered = ProviderIntegrationOperationSnapshot(
                    operationID: current.operationID,
                    kind: current.kind,
                    providerID: current.providerID,
                    phase: .failedRecoverable,
                    expectedRevision: current.expectedRevision,
                    resultingRevision: nil,
                    idempotencyKeySHA256: current.idempotencyKeySHA256,
                    intentSHA256: current.intentSHA256,
                    detail: "Forge restarted before the provider operation completed; the prior selection was retained.",
                    errorCode: "interrupted_by_restart",
                    acceptedAt: current.acceptedAt,
                    updatedAt: timestamp,
                    completedAt: timestamp
                )
            }
            archive(recovered, in: &reconciled)
            requiresPersistence = true
        }
        if reconciled.selectedProviderID == .grokBuild {
            reconciled.selectedProviderID = nil
            reconciled.selectionRevision = newRevision()
            requiresPersistence = true
        }
        if requiresPersistence {
            try persist(reconciled, to: url)
        }
        return reconciled
    }

    private static func validate(_ ledger: ProviderIntegrationLedger) throws {
        guard ledger.schemaVersion == ledgerSchemaVersion else {
            throw ProviderIntegrationError.ledgerCorrupt(reason: "unsupported_schema")
        }
        do {
            try ProviderIntegrationContract.validateText(
                ledger.selectionRevision,
                field: "selection_revision",
                maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
            )
            if let selected = ledger.selectedProviderID,
               selected != .grokBuild,
               !isSelectable(selected) {
                throw ProviderIntegrationError.ledgerCorrupt(
                    reason: "selected_provider_not_selectable"
                )
            }
            guard ledger.recentOperations.count <= ProviderIntegrationContract.maximumRecentOperations else {
                throw ProviderIntegrationError.ledgerCorrupt(reason: "history_exceeds_bound")
            }
            var receiptIDs = Set<ProviderIntegrationID>()
            for receipt in ledger.receipts {
                guard receiptIDs.insert(receipt.providerID).inserted else {
                    throw ProviderIntegrationError.ledgerCorrupt(
                        reason: "duplicate_provider_receipt"
                    )
                }
            }
            var operationIDs = Set<String>()
            let operations = (ledger.currentOperation.map { [$0.operation] } ?? [])
                + ledger.recentOperations.map(\.operation)
            for operation in operations {
                try validate(operation)
                guard operationIDs.insert(operation.operationID).inserted else {
                    throw ProviderIntegrationError.ledgerCorrupt(
                        reason: "duplicate_operation_id"
                    )
                }
            }
        } catch let error as ProviderIntegrationError {
            switch error {
            case .ledgerCorrupt: throw error
            default:
                throw ProviderIntegrationError.ledgerCorrupt(
                    reason: bounded(error.localizedDescription)
                )
            }
        }
    }

    private static func validate(
        _ operation: ProviderIntegrationOperationSnapshot
    ) throws {
        try ProviderIntegrationContract.validateText(
            operation.operationID,
            field: "operation_id",
            maximumBytes: ProviderIntegrationContract.maximumOperationIDBytes
        )
        try ProviderIntegrationContract.validateText(
            operation.expectedRevision,
            field: "expected_revision",
            maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
        )
        if let resultingRevision = operation.resultingRevision {
            try ProviderIntegrationContract.validateText(
                resultingRevision,
                field: "resulting_revision",
                maximumBytes: ProviderIntegrationContract.maximumRevisionBytes
            )
        }
        try ProviderIntegrationContract.validateSHA256(
            operation.idempotencyKeySHA256,
            field: "idempotency_key_sha256"
        )
        try ProviderIntegrationContract.validateSHA256(
            operation.intentSHA256,
            field: "intent_sha256"
        )
        if let detail = operation.detail {
            try ProviderIntegrationContract.validateText(
                detail,
                field: "detail",
                maximumBytes: ProviderIntegrationContract.maximumDetailBytes,
                permitsEmpty: true
            )
        }
        if let errorCode = operation.errorCode {
            try ProviderIntegrationContract.validateText(
                errorCode,
                field: "error_code",
                maximumBytes: 128
            )
        }
        guard ISO8601.date(from: operation.acceptedAt) != nil,
              ISO8601.date(from: operation.updatedAt) != nil,
              operation.completedAt.map({ ISO8601.date(from: $0) != nil }) ?? true else {
            throw ProviderIntegrationError.ledgerCorrupt(
                reason: "invalid_operation_timestamp"
            )
        }
    }

    private static func persist(
        _ ledger: ProviderIntegrationLedger,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ledger)
            guard data.count <= ProviderIntegrationContract.maximumLedgerBytes else {
                throw ProviderIntegrationError.persistenceFailed(
                    reason: "ledger_exceeds_bound"
                )
            }
            try OwnerOnlyAtomicFile.write(data, to: url)
        } catch let error as ProviderIntegrationError {
            throw error
        } catch {
            throw ProviderIntegrationError.persistenceFailed(
                reason: bounded(String(describing: error))
            )
        }
    }
}

private struct StoredProviderIntegrationOperation: Codable, Sendable, Equatable {
    let operation: ProviderIntegrationOperationSnapshot

    enum CodingKeys: String, CodingKey { case operation }
}

private struct ProviderIntegrationLedger: Codable, Sendable, Equatable {
    let schemaVersion: Int
    var selectionRevision: String
    var selectedProviderID: ProviderIntegrationID?
    var currentOperation: StoredProviderIntegrationOperation?
    var recentOperations: [StoredProviderIntegrationOperation]
    var receipts: [ProviderIntegrationReceipt]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case selectionRevision = "selection_revision"
        case selectedProviderID = "selected_provider_id"
        case currentOperation = "current_operation"
        case recentOperations = "recent_operations"
        case receipts
    }
}

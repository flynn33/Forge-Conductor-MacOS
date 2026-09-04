import Darwin
import Foundation
import ForgeFilesystemProtocol

final class PrivilegedLeafDeleteEngine {
    private static let namespaceName = ".forge-conductor-filesystem-v1"
    private static let slotsDirectoryName = "transactions"
    private static let bindingsDirectoryName = "project-bindings"
    private static let lockName = ".transactions.lock"
    private static let maximumTransactions = 32
    private static let maximumReceiptBytes = 32 * 1_024
    private static let maximumAcknowledgementBytes = 48 * 1_024
    private static let maximumBindingBytes = 8 * 1_024
    private static let capturedIdentityName = "captured-identity.json"
    private static let capturedIdentityPendingName = "captured-identity.json.pending"
    private static let terminalOutcomeName = "outcome.json"
    private static let terminalOutcomePendingName = "outcome.json.pending"
    private static let acknowledgingName = "acknowledging.json"
    private static let acknowledgingPendingName = "acknowledging.json.pending"

    private let processLock = NSLock()

    func deleteLeaf(
        _ request: ForgeFilesystemMutationRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) -> ForgeFilesystemResponse {
        guard geteuid() == 0 else {
            return failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem service is not running with its required identity"
            )
        }
        guard ForgeFilesystemRequesterPolicy.isValidRequesterUID(UInt32(requesterUID)),
              getpwuid(requesterUID) != nil else {
            return failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem requester identity is invalid"
            )
        }

        processLock.lock()
        defer { processLock.unlock() }

        do {
            return try performDelete(
                request,
                authorizedRootDescriptor: authorizedRootDescriptor,
                requesterUID: requesterUID
            )
        } catch let error as EngineFailure {
            return failure(
                code: error.code,
                message: error.message,
                committed: error.committed,
                durabilityConfirmed: error.durabilityConfirmed,
                recoveryTransactionID: error.recoveryTransactionID
            )
        } catch {
            return failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The protected filesystem mutation failed closed"
            )
        }
    }

    func queryTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) -> ForgeFilesystemTransactionStatus {
        guard servicePermits(requesterUID: requesterUID) else {
            return unavailableStatus(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }

        processLock.lock()
        defer { processLock.unlock() }

        do {
            return try performQuery(
                request,
                authorizedRootDescriptor: authorizedRootDescriptor,
                requesterUID: requesterUID
            )
        } catch {
            return unavailableStatus(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }
    }

    func resumeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) -> ForgeFilesystemResponse {
        guard servicePermits(requesterUID: requesterUID) else {
            return failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }

        processLock.lock()
        defer { processLock.unlock() }

        do {
            return try performResume(
                request,
                authorizedRootDescriptor: authorizedRootDescriptor,
                requesterUID: requesterUID
            )
        } catch let error as EngineFailure {
            return failure(
                code: error.code,
                message: error.message,
                committed: error.committed,
                durabilityConfirmed: error.durabilityConfirmed,
                recoveryTransactionID: error.recoveryTransactionID
            )
        } catch {
            return failure(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }
    }

    func acknowledgeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) -> ForgeFilesystemResponse {
        guard servicePermits(requesterUID: requesterUID) else {
            return failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }

        processLock.lock()
        defer { processLock.unlock() }

        do {
            return try performAcknowledgement(
                request,
                authorizedRootDescriptor: authorizedRootDescriptor,
                requesterUID: requesterUID
            )
        } catch let error as EngineFailure {
            return failure(
                code: error.code,
                message: error.message,
                committed: error.committed,
                durabilityConfirmed: error.durabilityConfirmed,
                recoveryTransactionID: error.recoveryTransactionID
            )
        } catch {
            return failure(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        }
    }

    private func servicePermits(requesterUID: uid_t) -> Bool {
        geteuid() == 0
            && ForgeFilesystemRequesterPolicy.isValidRequesterUID(UInt32(requesterUID))
            && getpwuid(requesterUID) != nil
    }

    private func performQuery(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemTransactionStatus {
        try withExistingTransactionInventory(
            request,
            authorizedRootDescriptor: authorizedRootDescriptor,
            requesterUID: requesterUID,
            reconcileAcknowledgements: false,
            ifMissing: unavailableStatus(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "The filesystem transaction is unavailable"
            )
        ) { inventory, rootInformation in
            guard let transaction = try controlledTransaction(
                for: request,
                requesterUID: requesterUID,
                rootInformation: rootInformation,
                in: inventory
            ) else {
                return unavailableStatus(
                    code: ForgeFilesystemErrorCode.transactionUnavailable,
                    message: "The filesystem transaction is unavailable"
                )
            }
            if let issue = transaction.recoveryIssue {
                return recoveryRequiredStatus(for: transaction, message: issue)
            }
            guard !transaction.acknowledging else {
                return unavailableStatus(
                    code: ForgeFilesystemErrorCode.transactionUnavailable,
                    message: "The filesystem transaction is unavailable"
                )
            }
            if let outcome = transaction.outcome {
                try synchronize(try requiredDescriptor(for: transaction.slot).rawValue)
                return outcome.status()
            }
            return recoveryRequiredStatus(
                for: transaction,
                message: "The filesystem transaction requires explicit recovery"
            )
        }
    }

    private func performResume(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        try withExistingTransactionInventory(
            request,
            authorizedRootDescriptor: authorizedRootDescriptor,
            requesterUID: requesterUID,
            reconcileAcknowledgements: true,
            ifMissing: transactionUnavailableResponse()
        ) { inventory, rootInformation in
            guard let transaction = try controlledTransaction(
                for: request,
                requesterUID: requesterUID,
                rootInformation: rootInformation,
                in: inventory
            ) else {
                return transactionUnavailableResponse()
            }
            try requireConsistentRecoveryState(transaction)
            guard !transaction.acknowledging else {
                return transactionUnavailableResponse()
            }
            if let outcome = transaction.outcome {
                return outcome.response()
            }

            return try preservingRecoveryIdentity(
                transactionID: transaction.record.transactionID
            ) {
                let root = try OwnedDescriptor(duplicating: authorizedRootDescriptor)
                return try resume(
                    transaction,
                    transactionID: transaction.record.transactionID,
                    rootDescriptor: root.rawValue,
                    requesterUID: requesterUID
                )
            }
        }
    }

    private func performAcknowledgement(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        try withExistingTransactionInventory(
            request,
            authorizedRootDescriptor: authorizedRootDescriptor,
            requesterUID: requesterUID,
            reconcileAcknowledgements: false,
            ifMissing: acknowledgementCompleteResponse()
        ) { inventory, rootInformation in
            let transaction = inventory.active.first(where: {
                $0.record.transactionID.caseInsensitiveCompare(
                    request.transactionID
                ) == .orderedSame
            })
            let authorityMatches = transaction?.record.authorizes(
                request,
                requesterUID: requesterUID,
                rootInformation: rootInformation
            ) ?? false
            switch ForgeFilesystemTransactionAuthorityPolicy.acknowledgementDecision(
                transactionExists: transaction != nil,
                authorityMatches: authorityMatches
            ) {
            case .idempotentSuccess:
                return acknowledgementCompleteResponse()
            case .reject:
                throw EngineFailure.transactionUnavailable()
            case .authorizedCleanup:
                break
            }
            guard let transaction else {
                throw EngineFailure.transactionUnavailable()
            }
            try requireConsistentRecoveryState(transaction)
            return try preservingRecoveryIdentity(
                transactionID: transaction.record.transactionID
            ) {
                let descriptor = try requiredDescriptor(for: transaction.slot).rawValue
                guard try namedInformationIfExists("leaf", in: descriptor) == nil else {
                    throw EngineFailure.namespace(
                        "The filesystem transaction still retains a protected leaf"
                    )
                }
                if transaction.acknowledging {
                    try finishAcknowledgement(slotDescriptor: descriptor)
                    return acknowledgementCompleteResponse()
                }
                guard let outcome = transaction.outcome else {
                    return failure(
                        code: ForgeFilesystemErrorCode.transactionNotTerminal,
                        message: "The filesystem transaction is not terminal",
                        recoveryTransactionID: transaction.record.transactionID
                    )
                }
                try writeAcknowledgement(
                    record: transaction.record,
                    outcome: outcome,
                    slotDescriptor: descriptor
                )
                try finishAcknowledgement(slotDescriptor: descriptor)
                return acknowledgementCompleteResponse()
            }
        }
    }

    private func withExistingTransactionInventory<Value>(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t,
        reconcileAcknowledgements: Bool,
        ifMissing missingValue: @autoclosure () -> Value,
        _ operation: (TransactionInventory, stat) throws -> Value
    ) throws -> Value {
        try validateControlRequest(request)
        let root = try OwnedDescriptor(duplicating: authorizedRootDescriptor)
        let rootInformation = try information(for: root.rawValue)
        try validateControlRoot(request, information: rootInformation)
        let volume = try qualifyVolume(rootDescriptor: root.rawValue, root: rootInformation)
        guard let namespace = try openExistingPrivateDirectory(
            named: Self.namespaceName,
            in: volume.mount.rawValue,
            expectedDevice: rootInformation.st_dev
        ), let slots = try openExistingPrivateDirectory(
            named: Self.slotsDirectoryName,
            in: namespace.rawValue,
            expectedDevice: rootInformation.st_dev
        ) else {
            return missingValue()
        }
        return try withNamespaceLock(
            namespaceDescriptor: namespace.rawValue,
            createIfMissing: false
        ) {
            let inventory = try transactionInventory(
                slotsDescriptor: slots.rawValue,
                expectedDevice: rootInformation.st_dev,
                reconcileAcknowledgements: reconcileAcknowledgements
            )
            return try operation(inventory, rootInformation)
        }
    }

    private func validateControlRequest(
        _ request: ForgeFilesystemTransactionControlRequest
    ) throws {
        guard request.validationError() == nil else {
            throw EngineFailure.capability("The filesystem transaction request is invalid")
        }
    }

    private func validateControlRoot(
        _ request: ForgeFilesystemTransactionControlRequest,
        information: stat
    ) throws {
        guard information.st_mode & S_IFMT == S_IFDIR,
              matchesRoot(request.rootIdentity, information),
              request.rootID == rootIdentifier(information) else {
            throw EngineFailure.capability("The authorized root identity does not match")
        }
    }

    private func controlledTransaction(
        for request: ForgeFilesystemTransactionControlRequest,
        requesterUID: uid_t,
        rootInformation: stat,
        in inventory: TransactionInventory
    ) throws -> ActiveTransaction? {
        guard let transaction = inventory.active.first(where: {
            $0.record.transactionID.caseInsensitiveCompare(request.transactionID) == .orderedSame
        }) else {
            return nil
        }
        guard transaction.record.authorizes(
            request,
            requesterUID: requesterUID,
            rootInformation: rootInformation
        ) else {
            throw EngineFailure.transactionUnavailable()
        }
        return transaction
    }

    private func recoveryRequiredStatus(
        for transaction: ActiveTransaction,
        message: String
    ) -> ForgeFilesystemTransactionStatus {
        ForgeFilesystemTransactionStatus(
            transactionID: transaction.record.transactionID,
            disposition: .recoveryRequired,
            code: ForgeFilesystemErrorCode.transactionNotTerminal,
            message: message,
            terminal: false,
            committed: false,
            durabilityConfirmed: false,
            recoveryRequired: true,
            acknowledgementRequired: false
        )
    }

    private func requireConsistentRecoveryState(_ transaction: ActiveTransaction) throws {
        if let issue = transaction.recoveryIssue {
            throw EngineFailure.namespace(
                issue,
                recoveryTransactionID: transaction.record.transactionID
            )
        }
    }

    private func performDelete(
        _ request: ForgeFilesystemMutationRequest,
        authorizedRootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        try validateRequest(request)

        let root = try OwnedDescriptor(duplicating: authorizedRootDescriptor)
        let rootInformation = try information(for: root.rawValue)
        try validateRoot(request, information: rootInformation)

        let volume = try qualifyVolume(rootDescriptor: root.rawValue, root: rootInformation)
        let namespace = try openProtectedNamespace(on: volume)
        let bindings = try openOrCreatePrivateDirectory(
            named: Self.bindingsDirectoryName,
            in: namespace.rawValue,
            expectedDevice: rootInformation.st_dev
        )
        let slots = try openOrCreatePrivateDirectory(
            named: Self.slotsDirectoryName,
            in: namespace.rawValue,
            expectedDevice: rootInformation.st_dev
        )

        return try withNamespaceLock(namespaceDescriptor: namespace.rawValue) {
            let inventory = try transactionInventory(
                slotsDescriptor: slots.rawValue,
                expectedDevice: rootInformation.st_dev
            )
            if let existing = try existingTransaction(
                for: request,
                requesterUID: requesterUID,
                in: inventory
            ) {
                return try preservingRecoveryIdentity(
                    transactionID: existing.record.transactionID,
                    boundary: .persistedTransactionPresent
                ) {
                    if existing.outcome == nil, existing.phase != .committed {
                        try validateProjectBinding(
                            request,
                            requesterUID: requesterUID,
                            rootInformation: rootInformation,
                            bindingsDescriptor: bindings.rawValue
                        )
                    }
                    return try resume(
                        existing,
                        transactionID: existing.record.transactionID,
                        rootDescriptor: root.rawValue,
                        requesterUID: requesterUID
                    )
                }
            }

            // Inventory is reconstructed under the protected namespace lock for
            // every admission, including the first call after daemon restart.
            // Explicit recovery of an exact transaction remains reachable above.
            // Never allocate another slot or advance a binding while a prior
            // effect is unresolved, even when the caller lost its own ledger.
            guard !inventory.active.contains(where: {
                $0.recoveryIssue != nil || $0.outcome == nil
            }) else {
                throw EngineFailure.namespace(
                    "Protected filesystem transactions require recovery before a new mutation"
                )
            }

            let parent = try openSourceParent(
                rootDescriptor: root.rawValue,
                components: request.relativePathComponents,
                expectedDevice: rootInformation.st_dev,
                requesterUID: requesterUID
            )
            guard let requestedLeafName = request.relativePathComponents.last else {
                throw EngineFailure.capability("The relative leaf path is invalid")
            }
            guard !requestedLeafName.isEmpty else {
                throw EngineFailure.capability("The relative leaf path is invalid")
            }
            guard !inventory.active.contains(where: {
                $0.outcome == nil
                    && $0.phase != .committed
                    && $0.record.projectID.caseInsensitiveCompare(request.projectID) == .orderedSame
                    && $0.record.projectGeneration != request.projectGeneration
            }) else {
                throw EngineFailure.capability(
                    "An earlier project generation has an active filesystem transaction"
                )
            }
            try validateProjectBinding(
                request,
                requesterUID: requesterUID,
                rootInformation: rootInformation,
                bindingsDescriptor: bindings.rawValue
            )

            let slot = try reserveSlot(from: inventory)
            let record = TransactionRecord(
                request: request,
                requesterUID: requesterUID,
                parentIdentity: FilesystemIdentity(parent.information)
            )
            return try preservingRecoveryIdentity(
                transactionID: request.transactionID,
                boundary: .intentPublicationStarted
            ) {
                try writePhase(
                    .intent,
                    record: record,
                    slotDescriptor: try requiredDescriptor(for: slot).rawValue
                )
                return try resume(
                    ActiveTransaction(slot: slot, phase: .intent, record: record),
                    transactionID: request.transactionID,
                    rootDescriptor: root.rawValue,
                    requesterUID: requesterUID,
                    allowInitialCapture: true
                )
            }
        }
    }

    private func validateRequest(_ request: ForgeFilesystemMutationRequest) throws {
        if let validationError = request.validationError() {
            switch validationError {
            case ForgeFilesystemErrorCode.protocolMismatch:
                throw EngineFailure.protocolMismatch(
                    "The filesystem mutation protocol version is unsupported"
                )
            case ForgeFilesystemErrorCode.requestReplayMismatch:
                throw EngineFailure.requestReplayMismatch(
                    "The filesystem mutation request digest does not match its fields"
                )
            default:
                throw EngineFailure.invalidRequest(
                    "The filesystem mutation request is invalid"
                )
            }
        }
        if request.contract == .contentVersionExact {
            throw EngineFailure.contentExclusivityUnavailable(
                "Exact-content deletion is unsupported without a qualified exclusive-writer proof"
            )
        }
        guard request.contract == .currentEntry
                || request.contract == .namespaceVersionExact else {
            throw EngineFailure.capability("The filesystem mutation contract is unsupported")
        }
    }

    private func validateRoot(
        _ request: ForgeFilesystemMutationRequest,
        information: stat
    ) throws {
        guard information.st_mode & S_IFMT == S_IFDIR,
              matchesRoot(request.rootIdentity, information),
              request.rootID == rootIdentifier(information) else {
            throw EngineFailure.capability("The authorized root identity does not match")
        }
    }

    private func qualifyVolume(rootDescriptor: Int32, root: stat) throws -> QualifiedVolume {
        var filesystem = statfs()
        guard Darwin.fstatfs(rootDescriptor, &filesystem) == 0 else {
            throw EngineFailure.volume("The authorized filesystem volume cannot be inspected")
        }
        let filesystemType = tupleCString(&filesystem.f_fstypename)
        let mountPath = tupleCString(&filesystem.f_mntonname)
        let flags = UInt64(filesystem.f_flags)
        guard filesystemType == "apfs",
              flags & UInt64(MNT_LOCAL) != 0,
              flags & UInt64(MNT_RDONLY) == 0,
              flags & UInt64(MNT_IGNORE_OWNERSHIP) == 0,
              mountPath.hasPrefix("/") else {
            throw EngineFailure.volume(
                "Protected mutations require local writable ownership-enforced APFS"
            )
        }

        let mountDescriptor = mountPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard mountDescriptor >= 0 else {
            throw EngineFailure.volume("The qualified volume root cannot be opened")
        }
        let mount = OwnedDescriptor(mountDescriptor)
        let mountInformation = try information(for: mount.rawValue)
        var openedFilesystem = statfs()
        let requiredWritableFlags = UInt64(MNT_RDONLY | MNT_IGNORE_OWNERSHIP)
        guard Darwin.fstatfs(mount.rawValue, &openedFilesystem) == 0,
              mountInformation.st_dev == root.st_dev,
              mountInformation.st_mode & S_IFMT == S_IFDIR,
              mountInformation.st_uid == 0,
              mountInformation.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              hasNoExtendedACL(mount.rawValue),
              UInt64(openedFilesystem.f_flags) & UInt64(MNT_LOCAL) != 0,
              UInt64(openedFilesystem.f_flags) & requiredWritableFlags == 0,
              tupleCString(&openedFilesystem.f_fstypename) == filesystemType,
              sameFilesystem(filesystem, openedFilesystem) else {
            throw EngineFailure.volume(
                "The APFS volume does not expose a root-controlled same-volume namespace"
            )
        }
        return QualifiedVolume(mount: mount, device: root.st_dev)
    }

    private func openProtectedNamespace(on volume: QualifiedVolume) throws -> OwnedDescriptor {
        do {
            return try openOrCreatePrivateDirectory(
                named: Self.namespaceName,
                in: volume.mount.rawValue,
                expectedDevice: volume.device
            )
        } catch {
            throw EngineFailure.namespace(
                "The protected transaction namespace is unavailable"
            )
        }
    }

    private func openOrCreatePrivateDirectory(
        named name: String,
        in parentDescriptor: Int32,
        expectedDevice: dev_t
    ) throws -> OwnedDescriptor {
        var created = false
        if name.withCString({ Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700)) }) != 0 {
            guard errno == EEXIST else {
                throw EngineFailure.namespace("A protected transaction directory cannot be created")
            }
        } else {
            created = true
        }

        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
            )
        }
        guard descriptor >= 0 else {
            throw EngineFailure.namespace("A protected transaction directory cannot be opened")
        }
        let directory = OwnedDescriptor(descriptor)
        let entryInformation = try namedInformation(name, in: parentDescriptor)
        let openedInformation = try information(for: descriptor)
        guard entryInformation.st_dev == expectedDevice,
              openedInformation.st_dev == expectedDevice,
              sameIdentity(entryInformation, openedInformation),
              openedInformation.st_mode & S_IFMT == S_IFDIR,
              openedInformation.st_uid == 0,
              openedInformation.st_mode & mode_t(0o777) == mode_t(0o700),
              hasNoExtendedACL(descriptor) else {
            throw EngineFailure.namespace(
                "A protected transaction directory failed ownership validation"
            )
        }
        if created {
            try synchronize(parentDescriptor)
            try synchronize(descriptor)
        }
        return directory
    }

    private func withNamespaceLock<Value>(
        namespaceDescriptor: Int32,
        createIfMissing: Bool = true,
        _ operation: () throws -> Value
    ) throws -> Value {
        let openFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
        let descriptor = Self.lockName.withCString {
            Darwin.openat(
                namespaceDescriptor,
                $0,
                openFlags,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw EngineFailure.namespace("The protected transaction lock is unavailable")
        }
        let lock = OwnedDescriptor(descriptor)
        let lockInformation = try information(for: lock.rawValue)
        guard lockInformation.st_mode & S_IFMT == S_IFREG,
              lockInformation.st_uid == 0,
              lockInformation.st_mode & mode_t(0o777) == mode_t(0o600),
              lockInformation.st_nlink == 1,
              hasNoExtendedACL(lock.rawValue) else {
            throw EngineFailure.namespace("The protected transaction lock is invalid")
        }
        guard flock(lock.rawValue, LOCK_EX | LOCK_NB) == 0 else {
            throw EngineFailure.namespace("The protected transaction namespace is busy")
        }
        defer { _ = flock(lock.rawValue, LOCK_UN) }
        return try operation()
    }

    private func validateProjectBinding(
        _ request: ForgeFilesystemMutationRequest,
        requesterUID: uid_t,
        rootInformation: stat,
        bindingsDescriptor: Int32
    ) throws {
        guard let projectUUID = UUID(uuidString: request.projectID) else {
            throw EngineFailure.capability("The project identifier is invalid")
        }
        let expected = ProjectBinding(
            request: request,
            requesterUID: requesterUID,
            rootInformation: rootInformation
        )
        var firstAvailableName: String?
        var existingName: String?
        var existingBinding: ProjectBinding?
        for slot in ForgeFilesystemBindingPolicy.probeSlots(for: projectUUID) {
            let name = String(format: "binding-%03d.json", slot)
            guard let existingData = try readOptionalFile(
                named: name,
                in: bindingsDescriptor,
                maximumBytes: Self.maximumBindingBytes
            ) else {
                if firstAvailableName == nil { firstAvailableName = name }
                continue
            }
            let existing: ProjectBinding
            do {
                existing = try JSONDecoder().decode(ProjectBinding.self, from: existingData)
            } catch {
                throw EngineFailure.namespace("A protected project binding is invalid")
            }
            guard existing.schemaVersion == ProjectBinding.currentSchema,
                  existing.projectGeneration > 0,
                  ForgeFilesystemRequesterPolicy.isValidRequesterUID(existing.requesterUID),
                  !existing.rootID.isEmpty else {
                throw EngineFailure.namespace("A protected project binding is invalid")
            }
            guard existing.projectID == expected.projectID else { continue }
            existingName = name
            existingBinding = existing
            break
        }

        if let existing = existingBinding {
            guard request.projectGeneration >= existing.projectGeneration else {
                throw EngineFailure.capability("The project generation is stale")
            }
            guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
                existing.requesterUID,
                currentRequesterUID: UInt32(requesterUID)
            ) else {
                throw EngineFailure.capability(
                    "The project binding belongs to a different filesystem requester"
                )
            }
            if request.projectGeneration == existing.projectGeneration {
                guard existing.sameRoot(as: expected) else {
                    throw EngineFailure.capability(
                        "The project generation is bound to a different authorized root"
                    )
                }
                return
            }
        }

        guard let name = existingName ?? firstAvailableName else {
            throw EngineFailure.namespace("The bounded project binding ledger is full")
        }

        try atomicallyReplaceFile(
            named: name,
            data: try JSONEncoder().encode(expected),
            in: bindingsDescriptor,
            maximumBytes: Self.maximumBindingBytes
        )
    }

    private func transactionInventory(
        slotsDescriptor: Int32,
        expectedDevice: dev_t,
        reconcileAcknowledgements: Bool = true
    ) throws -> TransactionInventory {
        var active: [ActiveTransaction] = []
        var emptySlots: [TransactionSlot] = []

        for index in 0..<Self.maximumTransactions {
            let name = String(format: "slot-%02d", index)
            guard let descriptor = try openExistingPrivateDirectory(
                named: name,
                in: slotsDescriptor,
                expectedDevice: expectedDevice
            ) else {
                emptySlots.append(TransactionSlot(
                    index: index,
                    parentDescriptor: slotsDescriptor,
                    expectedDevice: expectedDevice
                ))
                continue
            }
            let slot = TransactionSlot(index: index, descriptor: descriptor)
            guard let state = try loadTransaction(
                from: slot,
                reconcileAcknowledgements: reconcileAcknowledgements
            ) else {
                emptySlots.append(slot)
                continue
            }
            active.append(state)
        }
        return TransactionInventory(
            active: active,
            emptySlots: emptySlots
        )
    }

    private func existingTransaction(
        for request: ForgeFilesystemMutationRequest,
        requesterUID: uid_t,
        in inventory: TransactionInventory
    ) throws -> ActiveTransaction? {
        for transaction in inventory.active {
            if transaction.record.transactionID.caseInsensitiveCompare(
                request.transactionID
            ) == .orderedSame {
                guard transaction.record.matches(request, requesterUID: requesterUID) else {
                    throw EngineFailure.requestReplayMismatch(
                        "The filesystem transaction identifier conflicts with another request"
                    )
                }
                return transaction
            }
            if transaction.record.requestID.caseInsensitiveCompare(
                request.requestID
            ) == .orderedSame {
                throw EngineFailure.requestReplayMismatch(
                    "The filesystem request identifier is already bound to another transaction"
                )
            }
        }
        return nil
    }

    private func reserveSlot(from inventory: TransactionInventory) throws -> TransactionSlot {
        if let empty = inventory.emptySlots.first {
            if let descriptor = empty.descriptor { return TransactionSlot(index: empty.index, descriptor: descriptor) }
            guard let parentDescriptor = empty.parentDescriptor,
                  let expectedDevice = empty.expectedDevice else {
                throw EngineFailure.namespace("A vacant transaction slot is invalid")
            }
            let descriptor = try openOrCreatePrivateDirectory(
                named: String(format: "slot-%02d", empty.index),
                in: parentDescriptor,
                expectedDevice: expectedDevice
            )
            return TransactionSlot(index: empty.index, descriptor: descriptor)
        }
        throw EngineFailure.namespace(
            "The bounded transaction ledger is full and requires explicit acknowledgement"
        )
    }

    private func loadTransaction(
        from slot: TransactionSlot,
        reconcileAcknowledgements: Bool
    ) throws -> ActiveTransaction? {
        let slotDescriptor = try requiredDescriptor(for: slot).rawValue
        var selectedPhase: TransactionPhase?
        var selectedRecord: TransactionRecord?
        for phase in TransactionPhase.allCases {
            guard let data = try readOptionalFile(
                named: phase.fileName,
                in: slotDescriptor,
                maximumBytes: Self.maximumReceiptBytes
            ) else { continue }
            let record: TransactionRecord
            do {
                record = try JSONDecoder().decode(TransactionRecord.self, from: data)
            } catch {
                throw EngineFailure.namespace("A protected transaction receipt is invalid")
            }
            guard record.isStructurallyValid else {
                throw EngineFailure.namespace("A protected transaction receipt is invalid")
            }
            if let selectedRecord, selectedRecord != record {
                throw EngineFailure.namespace("Protected transaction phases do not agree")
            }
            selectedRecord = record
            selectedPhase = phase
        }

        let acknowledgement: TransactionAcknowledgement?
        if let data = try readOptionalFile(
            named: Self.acknowledgingName,
            in: slotDescriptor,
            maximumBytes: Self.maximumAcknowledgementBytes
        ) {
            do {
                acknowledgement = try JSONDecoder().decode(
                    TransactionAcknowledgement.self,
                    from: data
                )
            } catch {
                throw EngineFailure.namespace("A protected acknowledgement is invalid")
            }
            guard acknowledgement?.isStructurallyValid == true else {
                throw EngineFailure.namespace("A protected acknowledgement is invalid")
            }
        } else {
            acknowledgement = nil
        }

        let authoritativeRecord = selectedRecord ?? acknowledgement?.record
        if reconcileAcknowledgements, let selectedRecord {
            try reconcileCapturedIdentityPublication(
                record: selectedRecord,
                slotDescriptor: slotDescriptor
            )
        }
        let outcome: TransactionTerminalOutcome?
        if let data = try readOptionalFile(
            named: Self.terminalOutcomeName,
            in: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes
        ) {
            do {
                outcome = try JSONDecoder().decode(TransactionTerminalOutcome.self, from: data)
            } catch {
                throw EngineFailure.namespace("A protected terminal outcome is invalid")
            }
            guard let authoritativeRecord,
                  outcome?.isValid(for: authoritativeRecord) == true,
                  selectedPhase == nil || selectedPhase == outcome?.terminalPhase else {
                throw EngineFailure.namespace("A protected terminal outcome is invalid")
            }
            if authoritativeRecord.requestDigestSHA256 != nil,
               acknowledgement == nil {
                let capturedIdentity = try readCapturedIdentity(
                    record: authoritativeRecord,
                    slotDescriptor: slotDescriptor
                )
                guard outcome?.capturedIdentity == capturedIdentity else {
                    throw EngineFailure.namespace(
                        "A protected terminal outcome does not match its capture receipt"
                    )
                }
            }
        } else {
            outcome = nil
        }

        // Read the physical entry while the protected namespace lock is held.
        // Metadata receipts may be durable even when the corresponding effect
        // was rolled back by crash recovery, and must never conceal retained data.
        let protectedLeaf = try namedInformationIfExists("leaf", in: slotDescriptor)
        let durableOutcome = outcome ?? acknowledgement?.outcome
        let recoveryIssue: String?
        if let durableOutcome,
           !ForgeFilesystemTerminalReceiptPolicy.agreesWithProtectedLeaf(
               disposition: durableOutcome.disposition,
               leafExists: protectedLeaf != nil,
               leafMatchesCaptureReceipt: protectedLeaf.map {
                   durableOutcome.capturedIdentity?.matches($0) == true
               } ?? false
           ) {
            recoveryIssue = "The terminal receipt disagrees with the protected filesystem entry"
        } else {
            recoveryIssue = nil
        }

        if let acknowledgement {
            guard
                  selectedRecord == nil || selectedRecord == acknowledgement.record,
                  outcome == nil || outcome == acknowledgement.outcome else {
                throw EngineFailure.namespace("A protected acknowledgement is invalid")
            }
            if reconcileAcknowledgements, recoveryIssue == nil {
                try finishAcknowledgement(slotDescriptor: slotDescriptor)
                return nil
            }
            return ActiveTransaction(
                slot: slot,
                phase: selectedPhase ?? acknowledgement.outcome.terminalPhase,
                record: acknowledgement.record,
                outcome: acknowledgement.outcome,
                acknowledging: true,
                recoveryIssue: recoveryIssue
            )
        }

        guard let selectedRecord, let selectedPhase else {
            if protectedLeaf != nil {
                throw EngineFailure.namespace("An untracked protected leaf requires recovery")
            }
            if reconcileAcknowledgements {
                try removePendingPhaseFiles(slotDescriptor: slotDescriptor)
            }
            return nil
        }
        if reconcileAcknowledgements {
            try removePendingPhaseFiles(slotDescriptor: slotDescriptor)
        }
        return ActiveTransaction(
            slot: slot,
            phase: selectedPhase,
            record: selectedRecord,
            outcome: outcome,
            acknowledging: false,
            recoveryIssue: recoveryIssue
        )
    }

    private func resume(
        _ transaction: ActiveTransaction,
        transactionID: String,
        rootDescriptor: Int32,
        requesterUID: uid_t,
        allowInitialCapture: Bool = false
    ) throws -> ForgeFilesystemResponse {
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            transaction.record.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        ) else {
            throw EngineFailure.capability(
                "The filesystem transaction belongs to a different requester"
            )
        }
        try requireConsistentRecoveryState(transaction)
        if let outcome = transaction.outcome {
            return outcome.response()
        }
        let slotDescriptor = try preservingRecoveryIdentity(
            transactionID: transactionID
        ) {
            try requiredDescriptor(for: transaction.slot).rawValue
        }
        let protectedInformation = try preservingRecoveryIdentity(
            transactionID: transactionID
        ) {
            try namedInformationIfExists("leaf", in: slotDescriptor)
        }

        switch transaction.phase {
        case .committed:
            guard protectedInformation == nil else {
                throw EngineFailure.namespace(
                    "A committed transaction retains a protected leaf",
                    recoveryTransactionID: transactionID
                )
            }
            return try terminalResponse(
                disposition: .committed,
                record: transaction.record,
                slotDescriptor: slotDescriptor
            )

        case .captured:
            if protectedInformation == nil {
                // Absence does not prove the unlink completed. Preserve the
                // recovery handle instead of manufacturing a success receipt.
                throw EngineFailure.namespace(
                    "The captured entry is absent without a durable committed receipt",
                    recoveryTransactionID: transactionID
                )
            }
            return try preservingRecoveryIdentity(
                transactionID: transactionID
            ) {
                switch try capturedLeafDecision(
                    for: transaction.record,
                    slotDescriptor: slotDescriptor
                ) {
                case .commit:
                    return try terminalUnlink(
                        transaction,
                        transactionID: transactionID,
                        requesterUID: requesterUID
                    )
                case .quarantine(let identity, let code, let message):
                    return try quarantineCapturedLeaf(
                        transaction,
                        transactionID: transactionID,
                        capturedIdentity: identity,
                        code: code,
                        message: message,
                        requesterUID: requesterUID
                    )
                }
            }

        case .rollback:
            return try preservingRecoveryIdentity(
                transactionID: transactionID
            ) {
                guard protectedInformation != nil else {
                    guard transaction.record.isLegacyProtocolFourRecord else {
                        return try terminalResponse(
                            disposition: .conflicted,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor,
                            code: ForgeFilesystemErrorCode.restoreConflict,
                            message: "The protected capture is absent and restoration cannot be proven"
                        )
                    }
                    var legacyRestorationProven = false
                    do {
                        let parent = try reopenRecordedParent(
                            transaction.record,
                            rootDescriptor: rootDescriptor,
                            requesterUID: requesterUID
                        )
                        let sourceInformation = try inspectLeafForDeletion(
                            named: transaction.record.leafName,
                            in: parent.descriptor.rawValue
                        )
                        if transaction.record.expectedLeafIdentity?.matches(
                            sourceInformation
                        ) == true {
                            try synchronize(parent.descriptor.rawValue)
                            try synchronize(slotDescriptor)
                            legacyRestorationProven = true
                        }
                    } catch {
                        // A legacy record predates protected-capture identity
                        // receipts. Any inability to reopen, inspect, compare,
                        // or durably synchronize the restored source is an
                        // unprovable restoration, not a retryable recovery
                        // state. The terminal receipt write below remains
                        // outside this catch so its own failures still surface.
                        legacyRestorationProven = false
                    }
                    guard legacyRestorationProven else {
                        return try terminalResponse(
                            disposition: .conflicted,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor,
                            code: ForgeFilesystemErrorCode.restoreConflict,
                            message: "The restored legacy namespace identity cannot be proven"
                        )
                    }
                    return try terminalResponse(
                        disposition: .restored,
                        record: transaction.record,
                        slotDescriptor: slotDescriptor,
                        code: ForgeFilesystemErrorCode.capabilityUnavailable,
                        message: "The captured filesystem leaf was restored"
                    )
                }
                let capturedIdentity = try namedInformation(
                    "leaf",
                    in: slotDescriptor
                )
                return try quarantineCapturedLeaf(
                    transaction,
                    transactionID: transactionID,
                    capturedIdentity: FilesystemIdentity(capturedIdentity),
                    code: ForgeFilesystemErrorCode.versionConflict,
                    message: "The captured filesystem leaf remains in protected quarantine",
                    requesterUID: requesterUID
                )
            }

        case .intent:
            if protectedInformation != nil {
                return try preservingRecoveryIdentity(
                    transactionID: transactionID
                ) {
                    // Once the entry exists in the root-owned slot, its protected
                    // capture is authoritative. Reopening the user-controlled
                    // source parent would let a post-capture parent relocation
                    // block verification and terminal quarantine indefinitely.
                    try synchronize(slotDescriptor)
                    switch try capturedLeafDecision(
                        for: transaction.record,
                        slotDescriptor: slotDescriptor
                    ) {
                    case .quarantine(let identity, let code, let message):
                        return try quarantineCapturedLeaf(
                            transaction,
                            transactionID: transactionID,
                            capturedIdentity: identity,
                            code: code,
                            message: message,
                            requesterUID: requesterUID
                        )
                    case .commit(let identity):
                        try writeCapturedIdentity(
                            identity,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor
                        )
                        try writePhase(
                            .captured,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor
                        )
                        return try terminalUnlink(
                            ActiveTransaction(
                                slot: transaction.slot,
                                phase: .captured,
                                record: transaction.record
                            ),
                            transactionID: transactionID,
                            requesterUID: requesterUID
                        )
                    }
                }
            }

            // Only the invocation that just published this intent may select
            // the current source entry. After a lost reply or restart the name
            // may denote replacement data; replay is not fresh authorization.
            guard allowInitialCapture else {
                throw EngineFailure.namespace(
                    "The interrupted capture requires explicit disposition before retry",
                    recoveryTransactionID: transactionID
                )
            }

            let parent = try preservingRecoveryIdentity(
                transactionID: transactionID
            ) {
                try reopenRecordedParent(
                    transaction.record,
                    rootDescriptor: rootDescriptor,
                    requesterUID: requesterUID
                )
            }
            let sourceInformation = try preservingRecoveryIdentity(
                transactionID: transactionID
            ) {
                try namedInformationIfExists(
                    transaction.record.leafName,
                    in: parent.descriptor.rawValue
                )
            }
            guard sourceInformation != nil else {
                return try terminalResponse(
                    disposition: .rejected,
                    record: transaction.record,
                    slotDescriptor: slotDescriptor,
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "The requested filesystem leaf is absent"
                )
            }
            return try preservingRecoveryIdentity(
                transactionID: transactionID
            ) {
                try captureAndDelete(
                    transaction,
                    transactionID: transactionID,
                    parent: parent,
                    requesterUID: requesterUID
                )
            }
        }
    }

    private func preservingRecoveryIdentity<Result>(
        transactionID: String,
        boundary: ForgeFilesystemTransactionRecoveryBoundary = .persistedTransactionPresent,
        _ operation: () throws -> Result
    ) throws -> Result {
        guard let recoveryTransactionID = ForgeFilesystemTransactionRecoveryPolicy
            .recoveryTransactionID(transactionID, at: boundary) else {
            throw EngineFailure.capability(
                "The filesystem transaction identity is invalid"
            )
        }
        do {
            return try operation()
        } catch let failure as EngineFailure {
            guard failure.recoveryTransactionID == nil else { throw failure }
            throw EngineFailure(
                code: failure.code,
                message: failure.message,
                committed: failure.committed,
                durabilityConfirmed: failure.durabilityConfirmed,
                recoveryTransactionID: recoveryTransactionID
            )
        } catch {
            throw EngineFailure.namespace(
                "The protected filesystem transaction requires recovery",
                recoveryTransactionID: recoveryTransactionID
            )
        }
    }

    private func captureAndDelete(
        _ transaction: ActiveTransaction,
        transactionID: String,
        parent: SourceParent,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            transaction.record.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        ) else {
            throw EngineFailure.capability(
                "The filesystem transaction belongs to a different requester"
            )
        }
        let slotDescriptor = try requiredDescriptor(for: transaction.slot).rawValue
        do {
            return try ForgeFilesystemCaptureFirstCoordinator.perform(
                capture: {
                    let result = transaction.record.leafName.withCString { sourceName in
                        "leaf".withCString { destinationName in
                            Darwin.renameatx_np(
                                parent.descriptor.rawValue,
                                sourceName,
                                slotDescriptor,
                                destinationName,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                    guard result == 0 else {
                        throw AtomicCaptureFailure(code: errno)
                    }
                    return slotDescriptor
                },
                verify: { capturedSlotDescriptor in
                    try capturedLeafDecision(
                        for: transaction.record,
                        slotDescriptor: capturedSlotDescriptor
                    )
                },
                commit: { capturedIdentity in
                    do {
                        try synchronize(parent.descriptor.rawValue)
                        try synchronize(slotDescriptor)
                        try writeCapturedIdentity(
                            capturedIdentity,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor
                        )
                        try writePhase(
                            .captured,
                            record: transaction.record,
                            slotDescriptor: slotDescriptor
                        )
                    } catch {
                        throw EngineFailure.namespace(
                            "The protected capture requires recovery before deletion",
                            recoveryTransactionID: transactionID
                        )
                    }
                    return try terminalUnlink(
                        ActiveTransaction(
                            slot: transaction.slot,
                            phase: .captured,
                            record: transaction.record
                        ),
                        transactionID: transactionID,
                        requesterUID: requesterUID
                    )
                },
                quarantine: { capturedIdentity, code, message in
                    try synchronize(parent.descriptor.rawValue)
                    try synchronize(slotDescriptor)
                    return try quarantineCapturedLeaf(
                        transaction,
                        transactionID: transactionID,
                        capturedIdentity: capturedIdentity,
                        code: code,
                        message: message,
                        requesterUID: requesterUID
                    )
                }
            )
        } catch let captureFailure as AtomicCaptureFailure {
            let code = captureFailure.code
            if code == EXDEV {
                return try terminalResponse(
                    disposition: .rejected,
                    record: transaction.record,
                    slotDescriptor: slotDescriptor,
                    code: ForgeFilesystemErrorCode.volumeUnqualified,
                    message: "The protected namespace is not on the source volume"
                )
            }
            if code == ENOENT {
                return try terminalResponse(
                    disposition: .rejected,
                    record: transaction.record,
                    slotDescriptor: slotDescriptor,
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "The requested filesystem namespace changed"
                )
            }
            if code == EEXIST {
                throw EngineFailure.namespace(
                    "The protected capture slot is unexpectedly occupied",
                    recoveryTransactionID: transactionID
                )
            }
            if ForgeFilesystemAtomicCaptureFailurePolicy
                .isDeterministicNoMutationFailure(code) {
                return try terminalResponse(
                    disposition: .rejected,
                    record: transaction.record,
                    slotDescriptor: slotDescriptor,
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "Atomic capture was denied before namespace mutation"
                )
            }
            throw EngineFailure.namespace(
                "The protected atomic capture failed",
                recoveryTransactionID: transactionID
            )
        }
    }

    private func terminalUnlink(
        _ transaction: ActiveTransaction,
        transactionID: String,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            transaction.record.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        ) else {
            throw EngineFailure.capability(
                "The filesystem transaction belongs to a different requester"
            )
        }
        let descriptor = try requiredDescriptor(for: transaction.slot).rawValue
        let capturedIdentity: FilesystemIdentity
        switch try capturedLeafDecision(
            for: transaction.record,
            slotDescriptor: descriptor
        ) {
        case .commit(let identity):
            capturedIdentity = identity
        case .quarantine(let identity, let code, let message):
            return try quarantineCapturedLeaf(
                transaction,
                transactionID: transactionID,
                capturedIdentity: identity,
                code: code,
                message: message,
                requesterUID: requesterUID
            )
        }
        try writeCapturedIdentity(
            capturedIdentity,
            record: transaction.record,
            slotDescriptor: descriptor
        )

        // Quarantine and identity revalidation mitigate namespace replacement, but do
        // not eliminate content changes through an already-open writable descriptor or
        // a hard link. Exact-content deletion is therefore deliberately unsupported.
        guard "leaf".withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
            throw EngineFailure.namespace(
                "The protected leaf could not be deleted",
                recoveryTransactionID: transactionID
            )
        }
        do {
            try synchronize(descriptor)
            try writePhase(
                .committed,
                record: transaction.record,
                slotDescriptor: descriptor
            )
        } catch {
            throw EngineFailure.namespace(
                "The terminal deletion committed without confirmed receipt durability",
                committed: true,
                recoveryTransactionID: transactionID
            )
        }
        return try terminalResponse(
            disposition: .committed,
            record: transaction.record,
            slotDescriptor: descriptor,
            capturedIdentity: capturedIdentity
        )
    }

    private func quarantineCapturedLeaf(
        _ transaction: ActiveTransaction,
        transactionID: String,
        capturedIdentity: FilesystemIdentity,
        code: String,
        message: String,
        requesterUID: uid_t
    ) throws -> ForgeFilesystemResponse {
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            transaction.record.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        ) else {
            throw EngineFailure.capability(
                "The filesystem transaction belongs to a different requester"
            )
        }
        let slotDescriptor = try requiredDescriptor(for: transaction.slot).rawValue
        let durableCapturedIdentity = try readCapturedIdentity(
            record: transaction.record,
            slotDescriptor: slotDescriptor
        ) ?? capturedIdentity
        try writeCapturedIdentity(
            durableCapturedIdentity,
            record: transaction.record,
            slotDescriptor: slotDescriptor
        )
        try writePhase(
            .rollback,
            record: transaction.record,
            slotDescriptor: slotDescriptor
        )
        // A directory descriptor does not prove that its directory remains below
        // the authorized root. Automatic root-privileged restore is therefore
        // disabled. The mismatch becomes a durable terminal conflict while the
        // captured entry remains in the protected bounded slot. The slot cannot be
        // acknowledged or reused until a separately authorized disposition exists.
        switch ForgeFilesystemCapturedLeafRollbackPolicy.disposition {
        case .retainForRecovery:
            return try terminalResponse(
                disposition: .quarantined,
                record: transaction.record,
                slotDescriptor: slotDescriptor,
                capturedIdentity: durableCapturedIdentity,
                code: code,
                message: message
            )
        }
    }

    private func reopenRecordedParent(
        _ record: TransactionRecord,
        rootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> SourceParent {
        let rootInformation = try information(for: rootDescriptor)
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
                  record.requesterUID,
                  currentRequesterUID: UInt32(requesterUID)
              ),
              record.rootIdentity.matchesRoot(rootInformation),
              record.rootID == rootIdentifier(rootInformation) else {
            throw EngineFailure.capability("The recorded authorized root identity changed")
        }
        let parent = try openSourceParent(
            rootDescriptor: rootDescriptor,
            components: record.relativePathComponents,
            expectedDevice: rootInformation.st_dev,
            requesterUID: requesterUID
        )
        guard record.parentIdentity.matchesRoot(parent.information) else {
            throw EngineFailure.namespace(
                "The recorded source parent is no longer named by the authorized root"
            )
        }
        return parent
    }

    private func openSourceParent(
        rootDescriptor: Int32,
        components: [String],
        expectedDevice: dev_t,
        requesterUID: uid_t
    ) throws -> SourceParent {
        guard !components.isEmpty else {
            throw EngineFailure.capability("The relative leaf path is invalid")
        }
        let duplicatedRoot = try OwnedDescriptor(duplicating: rootDescriptor)
        var current = duplicatedRoot
        let parentComponents = Array(components.dropLast())
        try validateSourceDirectory(
            current.rawValue,
            expectedDevice: expectedDevice,
            requesterUID: requesterUID,
            requiresOwnerWrite: parentComponents.isEmpty
        )
        for (index, component) in parentComponents.enumerated() {
            let descriptor = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                )
            }
            guard descriptor >= 0 else {
                throw EngineFailure.capability("A relative source directory cannot be opened")
            }
            let next = OwnedDescriptor(descriptor)
            let nextInformation = try information(for: next.rawValue)
            guard nextInformation.st_dev == expectedDevice,
                  nextInformation.st_mode & S_IFMT == S_IFDIR else {
                throw EngineFailure.capability("The relative source path left its authorized volume")
            }
            try validateSourceDirectory(
                next.rawValue,
                expectedDevice: expectedDevice,
                requesterUID: requesterUID,
                requiresOwnerWrite: index == parentComponents.count - 1
            )
            current = next
        }
        let parentInformation = try information(for: current.rawValue)
        guard parentInformation.st_dev == expectedDevice,
              parentInformation.st_mode & S_IFMT == S_IFDIR else {
            throw EngineFailure.capability("The source parent is invalid")
        }
        return SourceParent(
            descriptor: current,
            information: parentInformation
        )
    }

    private func validateSourceDirectory(
        _ descriptor: Int32,
        expectedDevice: dev_t,
        requesterUID: uid_t,
        requiresOwnerWrite: Bool
    ) throws {
        let directoryInformation = try information(for: descriptor)
        let hasExtendedACL = !hasNoExtendedACL(descriptor)
        guard directoryInformation.st_dev == expectedDevice,
              ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
                  requesterUID: UInt32(requesterUID),
                  ownerUID: UInt32(directoryInformation.st_uid),
                  mode: UInt32(directoryInformation.st_mode),
                  hasExtendedACL: hasExtendedACL,
                  requiresOwnerWrite: requiresOwnerWrite
              ) else {
            throw EngineFailure.capability(
                requiresOwnerWrite
                    ? "The source parent is not an ACL-free requester-owned writable directory"
                    : "The source path is not an ACL-free requester-owned searchable directory"
            )
        }
    }

    private func capturedLeafDecision(
        for record: TransactionRecord,
        slotDescriptor: Int32
    ) throws -> ForgeFilesystemCapturedMutationDecision<FilesystemIdentity> {
        let named = try namedInformation("leaf", in: slotDescriptor)
        let identity = FilesystemIdentity(named)
        if let durableCapturedIdentity = try readCapturedIdentity(
            record: record,
            slotDescriptor: slotDescriptor
        ), !durableCapturedIdentity.matches(named) {
            return .quarantine(
                durableCapturedIdentity,
                code: ForgeFilesystemErrorCode.versionConflict,
                message: "The protected entry metadata changed after atomic capture"
            )
        }
        switch record.contract {
        case .namespaceVersionExact:
            guard record.expectedLeafIdentity?.matches(named) == true else {
                return .quarantine(
                    identity,
                    code: ForgeFilesystemErrorCode.versionConflict,
                    message: "The captured namespace version does not match the requested version"
                )
            }
        case .currentEntry:
            break
        case .contentVersionExact:
            return .quarantine(
                identity,
                code: ForgeFilesystemErrorCode.contentExclusivityUnavailable,
                message: "Exact-content deletion lacks a qualified exclusive-writer proof"
            )
        case nil:
            return .quarantine(
                identity,
                code: ForgeFilesystemErrorCode.invalidRequest,
                message: "The protected filesystem operation contract is invalid"
            )
        }
        do {
            _ = try inspectLeafForDeletion(named: "leaf", in: slotDescriptor)
        } catch {
            return .quarantine(
                identity,
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The captured entry type, ACL, or BSD flags do not permit deletion"
            )
        }
        return .commit(identity)
    }

    private func inspectLeafForDeletion(
        named name: String,
        in parentDescriptor: Int32
    ) throws -> stat {
        let named = try namedInformation(name, in: parentDescriptor)
        guard ForgeFilesystemRequesterPolicy.permitsLeafType(mode: UInt32(named.st_mode)) else {
            throw EngineFailure.capability(
                "Only a regular file or symbolic link is eligible for protected deletion"
            )
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_EVTONLY | O_NONBLOCK | O_CLOEXEC | O_SYMLINK | O_RESOLVE_BENEATH
            )
        }
        guard descriptor >= 0 else {
            throw EngineFailure.capability(
                "The requested filesystem leaf cannot be inspected safely"
            )
        }
        let leaf = OwnedDescriptor(descriptor)
        let leafInformation = try information(for: leaf.rawValue)
        guard sameIdentity(named, leafInformation),
              ForgeFilesystemRequesterPolicy.permitsLeafType(
                  mode: UInt32(leafInformation.st_mode)
              ),
              ForgeFilesystemRequesterPolicy.permitsLeafDeletion(
                  flags: UInt32(leafInformation.st_flags),
                  hasExtendedACL: !hasNoExtendedACL(leaf.rawValue)
              ) else {
            throw EngineFailure.capability(
                "The requested leaf identity, ACL, or flags do not permit deletion"
            )
        }
        return leafInformation
    }

    private func openExistingPrivateDirectory(
        named name: String,
        in parentDescriptor: Int32,
        expectedDevice: dev_t
    ) throws -> OwnedDescriptor? {
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw EngineFailure.namespace("A transaction slot cannot be opened")
        }
        let directory = OwnedDescriptor(descriptor)
        let directoryInformation = try information(for: directory.rawValue)
        guard directoryInformation.st_dev == expectedDevice,
              directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_uid == 0,
              directoryInformation.st_mode & mode_t(0o777) == mode_t(0o700),
              hasNoExtendedACL(directory.rawValue) else {
            throw EngineFailure.namespace("A transaction slot failed ownership validation")
        }
        return directory
    }

    private func removePhaseFiles(in descriptor: Int32) throws {
        for phase in TransactionPhase.allCases {
            try unlinkIfExists(phase.pendingFileName, in: descriptor)
            try unlinkIfExists(phase.fileName, in: descriptor)
        }
        try unlinkIfExists(Self.capturedIdentityPendingName, in: descriptor)
        try unlinkIfExists(Self.capturedIdentityName, in: descriptor)
        try synchronize(descriptor)
    }

    private func removePendingPhaseFiles(slotDescriptor: Int32) throws {
        for phase in TransactionPhase.allCases {
            try unlinkIfExists(phase.pendingFileName, in: slotDescriptor)
        }
        try unlinkIfExists(Self.capturedIdentityPendingName, in: slotDescriptor)
        try unlinkIfExists(Self.terminalOutcomePendingName, in: slotDescriptor)
        try unlinkIfExists(Self.acknowledgingPendingName, in: slotDescriptor)
        try synchronize(slotDescriptor)
    }

    private func writeCapturedIdentity(
        _ identity: FilesystemIdentity,
        record: TransactionRecord,
        slotDescriptor: Int32
    ) throws {
        let receipt = CapturedLeafReceipt(record: record, identity: identity)
        guard receipt.isValid(for: record) else {
            throw EngineFailure.namespace("A captured filesystem identity is invalid")
        }
        try writeExclusiveMetadata(
            receipt,
            named: Self.capturedIdentityName,
            pendingName: Self.capturedIdentityPendingName,
            slotDescriptor: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes,
            conflictMessage: "A captured filesystem identity conflicts with its receipt"
        )
    }

    private func readCapturedIdentity(
        record: TransactionRecord,
        slotDescriptor: Int32
    ) throws -> FilesystemIdentity? {
        guard let data = try readOptionalFile(
            named: Self.capturedIdentityName,
            in: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes
        ) else { return nil }
        guard let receipt = try? JSONDecoder().decode(CapturedLeafReceipt.self, from: data),
              receipt.isValid(for: record) else {
            throw EngineFailure.namespace("A captured filesystem identity receipt is invalid")
        }
        return receipt.identity
    }

    private func reconcileCapturedIdentityPublication(
        record: TransactionRecord,
        slotDescriptor: Int32
    ) throws {
        guard let pendingData = try readOptionalFile(
            named: Self.capturedIdentityPendingName,
            in: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes
        ) else { return }
        guard let pendingReceipt = try? JSONDecoder().decode(
            CapturedLeafReceipt.self,
            from: pendingData
        ), pendingReceipt.isValid(for: record) else {
            throw EngineFailure.namespace(
                "A pending captured filesystem identity receipt is invalid"
            )
        }

        if let publishedData = try readOptionalFile(
            named: Self.capturedIdentityName,
            in: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes
        ) {
            guard let publishedReceipt = try? JSONDecoder().decode(
                CapturedLeafReceipt.self,
                from: publishedData
            ), publishedReceipt.isValid(for: record),
               publishedReceipt == pendingReceipt else {
                throw EngineFailure.namespace(
                    "A pending captured filesystem identity conflicts with its receipt"
                )
            }
            try unlinkIfExists(Self.capturedIdentityPendingName, in: slotDescriptor)
            try synchronize(slotDescriptor)
            return
        }

        let result = Self.capturedIdentityPendingName.withCString { sourceName in
            Self.capturedIdentityName.withCString { destinationName in
                Darwin.renameatx_np(
                    slotDescriptor,
                    sourceName,
                    slotDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw EngineFailure.namespace(
                "A pending captured filesystem identity cannot be published"
            )
        }
        try synchronize(slotDescriptor)
    }

    private func writeTerminalOutcome(
        _ outcome: TransactionTerminalOutcome,
        slotDescriptor: Int32
    ) throws {
        try writeExclusiveMetadata(
            outcome,
            named: Self.terminalOutcomeName,
            pendingName: Self.terminalOutcomePendingName,
            slotDescriptor: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes,
            conflictMessage: "A terminal transaction outcome conflicts with its receipt"
        )
    }

    private func writeAcknowledgement(
        record: TransactionRecord,
        outcome: TransactionTerminalOutcome,
        slotDescriptor: Int32
    ) throws {
        let acknowledgement = TransactionAcknowledgement(
            record: record,
            outcome: outcome
        )
        guard acknowledgement.isStructurallyValid else {
            throw EngineFailure.namespace("A protected acknowledgement is invalid")
        }
        try writeExclusiveMetadata(
            acknowledgement,
            named: Self.acknowledgingName,
            pendingName: Self.acknowledgingPendingName,
            slotDescriptor: slotDescriptor,
            maximumBytes: Self.maximumAcknowledgementBytes,
            conflictMessage: "A protected acknowledgement conflicts with its receipt"
        )
    }

    private func writeExclusiveMetadata<Value: Codable & Equatable>(
        _ value: Value,
        named name: String,
        pendingName: String,
        slotDescriptor: Int32,
        maximumBytes: Int,
        conflictMessage: String
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumBytes else {
            throw EngineFailure.capability("The bounded transaction receipt is too large")
        }
        if let existing = try readOptionalFile(
            named: name,
            in: slotDescriptor,
            maximumBytes: maximumBytes
        ) {
            guard let decoded = try? JSONDecoder().decode(Value.self, from: existing),
                  decoded == value else {
                throw EngineFailure.namespace(conflictMessage)
            }
            try synchronize(slotDescriptor)
            return
        }

        try unlinkIfExists(pendingName, in: slotDescriptor)
        try synchronize(slotDescriptor)
        try createDurableFile(
            named: pendingName,
            data: encoded,
            in: slotDescriptor
        )
        let result = pendingName.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameatx_np(
                    slotDescriptor,
                    sourceName,
                    slotDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw EngineFailure.namespace("Protected transaction metadata cannot be published")
        }
        try synchronize(slotDescriptor)
    }

    private func finishAcknowledgement(slotDescriptor: Int32) throws {
        guard try namedInformationIfExists("leaf", in: slotDescriptor) == nil else {
            throw EngineFailure.namespace("A protected leaf prevents acknowledgement")
        }

        // The durable acknowledging record is removed last. A crash before that
        // point leaves enough authority and outcome data to finish cleanup on retry.
        try removePhaseFiles(in: slotDescriptor)
        try unlinkIfExists(Self.terminalOutcomePendingName, in: slotDescriptor)
        try unlinkIfExists(Self.terminalOutcomeName, in: slotDescriptor)
        try unlinkIfExists(Self.acknowledgingPendingName, in: slotDescriptor)
        try synchronize(slotDescriptor)
        try unlinkIfExists(Self.acknowledgingName, in: slotDescriptor)
        try synchronize(slotDescriptor)
    }

    private func requiredDescriptor(for slot: TransactionSlot) throws -> OwnedDescriptor {
        guard let descriptor = slot.descriptor else {
            throw EngineFailure.namespace("A transaction slot descriptor is unavailable")
        }
        return descriptor
    }

    private func writePhase(
        _ phase: TransactionPhase,
        record: TransactionRecord,
        slotDescriptor: Int32
    ) throws {
        let encoded = try JSONEncoder().encode(record)
        guard encoded.count <= Self.maximumReceiptBytes else {
            throw EngineFailure.capability("The bounded transaction receipt is too large")
        }
        if let existing = try readOptionalFile(
            named: phase.fileName,
            in: slotDescriptor,
            maximumBytes: Self.maximumReceiptBytes
        ) {
            guard let decoded = try? JSONDecoder().decode(
                TransactionRecord.self,
                from: existing
            ), decoded == record else {
                throw EngineFailure.namespace("A transaction phase conflicts with its receipt")
            }
            try synchronize(slotDescriptor)
            return
        }

        try unlinkIfExists(phase.pendingFileName, in: slotDescriptor)
        try synchronize(slotDescriptor)
        try createDurableFile(
            named: phase.pendingFileName,
            data: encoded,
            in: slotDescriptor
        )
        let result = phase.pendingFileName.withCString { sourceName in
            phase.fileName.withCString { destinationName in
                Darwin.renameatx_np(
                    slotDescriptor,
                    sourceName,
                    slotDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw EngineFailure.namespace("A transaction phase cannot be published atomically")
        }
        try synchronize(slotDescriptor)
    }

    private func atomicallyReplaceFile(
        named name: String,
        data: Data,
        in directoryDescriptor: Int32,
        maximumBytes: Int
    ) throws {
        guard data.count <= maximumBytes else {
            throw EngineFailure.capability("The protected metadata is too large")
        }
        let pending = name + ".pending"
        try unlinkIfExists(pending, in: directoryDescriptor)
        try synchronize(directoryDescriptor)
        try createDurableFile(named: pending, data: data, in: directoryDescriptor)
        let result = pending.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameat(directoryDescriptor, sourceName, directoryDescriptor, destinationName)
            }
        }
        guard result == 0 else {
            throw EngineFailure.namespace("A protected project binding cannot be published")
        }
        try synchronize(directoryDescriptor)
    }

    private func createDurableFile(
        named name: String,
        data: Data,
        in directoryDescriptor: Int32
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw EngineFailure.namespace("Protected metadata storage is unavailable")
        }
        let file = OwnedDescriptor(descriptor)
        let fileInformation = try information(for: file.rawValue)
        guard fileInformation.st_mode & S_IFMT == S_IFREG,
              fileInformation.st_uid == 0,
              fileInformation.st_mode & mode_t(0o777) == mode_t(0o600),
              fileInformation.st_nlink == 1,
              hasNoExtendedACL(file.rawValue) else {
            throw EngineFailure.namespace("Protected metadata ownership is invalid")
        }
        try writeAll(data, to: file.rawValue)
        try synchronize(file.rawValue)
    }

    private func readOptionalFile(
        named name: String,
        in directoryDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw EngineFailure.namespace("Protected metadata cannot be opened")
        }
        let file = OwnedDescriptor(descriptor)
        let fileInformation = try information(for: file.rawValue)
        guard fileInformation.st_mode & S_IFMT == S_IFREG,
              fileInformation.st_uid == 0,
              fileInformation.st_mode & mode_t(0o777) == mode_t(0o600),
              fileInformation.st_nlink == 1,
              hasNoExtendedACL(file.rawValue),
              fileInformation.st_size >= 0,
              fileInformation.st_size <= off_t(maximumBytes) else {
            throw EngineFailure.namespace("Protected metadata failed validation")
        }
        var data = Data()
        data.reserveCapacity(Int(fileInformation.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes))
        while data.count <= maximumBytes {
            let count = Darwin.read(file.rawValue, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.count > maximumBytes {
                    throw EngineFailure.namespace("Protected metadata exceeds its bound")
                }
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw EngineFailure.namespace("Protected metadata cannot be read")
            }
        }
        throw EngineFailure.namespace("Protected metadata exceeds its bound")
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw EngineFailure.namespace("Protected metadata cannot be written")
                }
            }
        }
    }

    private func unlinkIfExists(_ name: String, in directoryDescriptor: Int32) throws {
        guard name.withCString({ Darwin.unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
            if errno == ENOENT { return }
            throw EngineFailure.namespace("Protected metadata cannot be removed")
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw EngineFailure.namespace("Protected filesystem durability cannot be confirmed")
        }
    }

    private func information(for descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw EngineFailure.capability("A filesystem descriptor identity cannot be read")
        }
        return value
    }

    private func namedInformation(_ name: String, in directoryDescriptor: Int32) throws -> stat {
        guard let value = try namedInformationIfExists(name, in: directoryDescriptor) else {
            throw EngineFailure.capability("A required filesystem leaf is absent")
        }
        return value
    }

    private func namedInformationIfExists(
        _ name: String,
        in directoryDescriptor: Int32
    ) throws -> stat? {
        var value = stat()
        let result = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw EngineFailure.capability("A filesystem namespace entry cannot be inspected")
        }
        return value
    }

    private func matchesRoot(_ expected: ForgeFilesystemIdentity, _ actual: stat) -> Bool {
        UInt64(actual.st_dev) == expected.device
            && UInt64(actual.st_ino) == expected.inode
            && UInt32(actual.st_mode) == expected.mode
            && UInt32(actual.st_uid) == expected.owner
            && UInt32(actual.st_gid) == expected.group
    }

    private func matchesLeaf(_ expected: ForgeFilesystemIdentity, _ actual: stat) -> Bool {
        matchesRoot(expected, actual) && UInt64(actual.st_nlink) == expected.linkCount
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func sameFilesystem(_ lhs: statfs, _ rhs: statfs) -> Bool {
        var lhsValue = lhs.f_fsid
        var rhsValue = rhs.f_fsid
        return withUnsafeBytes(of: &lhsValue) { lhsBytes in
            withUnsafeBytes(of: &rhsValue) { rhsBytes in
                lhsBytes.elementsEqual(rhsBytes)
            }
        }
    }

    private func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        _ = acl_free(UnsafeMutableRawPointer(accessControlList))
        return false
    }

    private func tupleCString<Value>(_ value: inout Value) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Value>.size) {
                String(cString: $0)
            }
        }
    }

    private func rootIdentifier(_ information: stat) -> String {
        "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    }

    private func terminalResponse(
        disposition: ForgeFilesystemTransactionDisposition,
        record: TransactionRecord,
        slotDescriptor: Int32,
        capturedIdentity: FilesystemIdentity? = nil,
        code: String = "ok",
        message: String = "The protected filesystem leaf was deleted"
    ) throws -> ForgeFilesystemResponse {
        let durableCapturedIdentity: FilesystemIdentity?
        if let capturedIdentity {
            durableCapturedIdentity = capturedIdentity
        } else {
            durableCapturedIdentity = try readCapturedIdentity(
                record: record,
                slotDescriptor: slotDescriptor
            )
        }
        let outcome = TransactionTerminalOutcome(
            transactionID: record.transactionID,
            disposition: disposition,
            ok: disposition == .committed,
            code: code,
            message: message,
            committed: disposition == .committed,
            durabilityConfirmed: true,
            recoveryTransactionID: record.transactionID,
            acknowledgementRequired: disposition != .quarantined,
            capturedIdentity: durableCapturedIdentity
        )
        guard outcome.isValid(for: record) else {
            throw EngineFailure.namespace("A terminal transaction outcome is invalid")
        }
        // The same physical-state rule applies to the first response as to
        // replay. A stale capture identity must not publish a terminal receipt
        // that the very next inventory scan would reject.
        let protectedLeaf = try namedInformationIfExists("leaf", in: slotDescriptor)
        guard ForgeFilesystemTerminalReceiptPolicy.agreesWithProtectedLeaf(
            disposition: outcome.disposition,
            leafExists: protectedLeaf != nil,
            leafMatchesCaptureReceipt: protectedLeaf.map {
                outcome.capturedIdentity?.matches($0) == true
            } ?? false
        ) else {
            throw EngineFailure.namespace(
                "The terminal outcome disagrees with the protected filesystem entry",
                recoveryTransactionID: record.transactionID
            )
        }
        do {
            try writeTerminalOutcome(outcome, slotDescriptor: slotDescriptor)
        } catch {
            throw EngineFailure.namespace(
                "The terminal filesystem outcome requires durable recovery",
                committed: disposition == .committed,
                recoveryTransactionID: record.transactionID
            )
        }
        return outcome.response()
    }

    private func unavailableStatus(
        code: String,
        message: String
    ) -> ForgeFilesystemTransactionStatus {
        ForgeFilesystemTransactionStatus(
            transactionID: nil,
            disposition: .unavailable,
            code: code,
            message: message,
            terminal: false,
            committed: false,
            durabilityConfirmed: false,
            recoveryRequired: false,
            acknowledgementRequired: false
        )
    }

    private func transactionUnavailableResponse() -> ForgeFilesystemResponse {
        failure(
            code: ForgeFilesystemErrorCode.transactionUnavailable,
            message: "The filesystem transaction is unavailable"
        )
    }

    private func acknowledgementCompleteResponse() -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "The filesystem transaction acknowledgement is complete",
            committed: false,
            durabilityConfirmed: true,
            recoveryTransactionID: nil,
            acknowledgementRequired: false
        )
    }

    private func failure(
        code: String,
        message: String,
        committed: Bool = false,
        durabilityConfirmed: Bool = false,
        recoveryTransactionID: String? = nil
    ) -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: false,
            code: code,
            message: message,
            committed: committed,
            durabilityConfirmed: durabilityConfirmed,
            recoveryTransactionID: recoveryTransactionID
        )
    }
}

private struct QualifiedVolume {
    let mount: OwnedDescriptor
    let device: dev_t
}

private final class OwnedDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    convenience init(duplicating descriptor: Int32) throws {
        let duplicated = Darwin.dup(descriptor)
        guard duplicated >= 0 else { throw POSIXFailure(errno) }
        guard Darwin.fcntl(duplicated, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            _ = Darwin.close(duplicated)
            throw POSIXFailure(code)
        }
        self.init(duplicated)
    }

    deinit {
        _ = Darwin.close(rawValue)
    }
}

private struct POSIXFailure: Error {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }
}

private struct AtomicCaptureFailure: Error {
    let code: Int32
}

private struct EngineFailure: Error {
    let code: String
    let message: String
    let committed: Bool
    let durabilityConfirmed: Bool
    let recoveryTransactionID: String?

    static func capability(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.capabilityUnavailable,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func invalidRequest(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.invalidRequest,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func protocolMismatch(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.protocolMismatch,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func volume(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.volumeUnqualified,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func contentExclusivityUnavailable(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.contentExclusivityUnavailable,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func requestReplayMismatch(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.requestReplayMismatch,
            message: message,
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func transactionUnavailable() -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.transactionUnavailable,
            message: "The filesystem transaction is unavailable",
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: nil
        )
    }

    static func namespace(
        _ message: String,
        committed: Bool = false,
        recoveryTransactionID: String? = nil
    ) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.protectedNamespaceUnavailable,
            message: message,
            committed: committed,
            durabilityConfirmed: false,
            recoveryTransactionID: recoveryTransactionID
        )
    }
}

private struct SourceParent {
    let descriptor: OwnedDescriptor
    let information: stat
}

private struct FilesystemIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let linkCount: UInt64

    init(_ information: stat) {
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
        mode = UInt32(information.st_mode)
        owner = UInt32(information.st_uid)
        group = UInt32(information.st_gid)
        linkCount = UInt64(information.st_nlink)
    }

    init(_ identity: ForgeFilesystemIdentity) {
        device = identity.device
        inode = identity.inode
        mode = identity.mode
        owner = identity.owner
        group = identity.group
        linkCount = identity.linkCount
    }

    func matches(_ information: stat) -> Bool {
        device == UInt64(information.st_dev)
            && inode == UInt64(information.st_ino)
            && mode == UInt32(information.st_mode)
            && owner == UInt32(information.st_uid)
            && group == UInt32(information.st_gid)
            && linkCount == UInt64(information.st_nlink)
    }

    func matchesRoot(_ information: stat) -> Bool {
        device == UInt64(information.st_dev)
            && inode == UInt64(information.st_ino)
            && mode == UInt32(information.st_mode)
            && owner == UInt32(information.st_uid)
            && group == UInt32(information.st_gid)
    }
}

private struct ProjectBinding: Codable {
    static let currentSchema = 2

    let schemaVersion: Int
    let projectID: String
    let projectGeneration: UInt64
    let requesterUID: UInt32
    let rootID: String
    let rootIdentity: FilesystemIdentity

    init(
        request: ForgeFilesystemMutationRequest,
        requesterUID: uid_t,
        rootInformation: stat
    ) {
        schemaVersion = Self.currentSchema
        projectID = request.projectID.lowercased()
        projectGeneration = request.projectGeneration
        self.requesterUID = UInt32(requesterUID)
        rootID = request.rootID
        rootIdentity = FilesystemIdentity(rootInformation)
    }

    func sameRoot(as other: ProjectBinding) -> Bool {
        requesterUID == other.requesterUID
            && rootID == other.rootID
            && rootIdentity.device == other.rootIdentity.device
            && rootIdentity.inode == other.rootIdentity.inode
            && rootIdentity.mode == other.rootIdentity.mode
            && rootIdentity.owner == other.rootIdentity.owner
            && rootIdentity.group == other.rootIdentity.group
    }
}

private struct TransactionRecord: Codable, Equatable {
    static let legacyProtocolFourSchema = 2
    static let currentSchema = 3

    let schemaVersion: Int
    let createdAtMilliseconds: Int64
    let requestID: String
    let transactionID: String
    let projectID: String
    let projectGeneration: UInt64
    let requesterUID: UInt32
    let rootID: String
    let rootIdentity: FilesystemIdentity
    let relativePathComponents: [String]
    let accessRawValue: Int
    let contractRawValue: Int?
    let requestProtocolVersion: Int?
    let requestDigestCanonicalizationVersion: Int?
    let expectedLeafIdentity: FilesystemIdentity?
    let requestDigestSHA256: String?
    let parentIdentity: FilesystemIdentity

    init(
        request: ForgeFilesystemMutationRequest,
        requesterUID: uid_t,
        parentIdentity: FilesystemIdentity
    ) {
        schemaVersion = Self.currentSchema
        createdAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        requestID = request.requestID.lowercased()
        transactionID = request.transactionID.lowercased()
        projectID = request.projectID.lowercased()
        projectGeneration = request.projectGeneration
        self.requesterUID = UInt32(requesterUID)
        rootID = request.rootID
        rootIdentity = FilesystemIdentity(request.rootIdentity)
        relativePathComponents = request.relativePathComponents
        accessRawValue = request.accessRawValue
        contractRawValue = request.contractRawValue
        requestProtocolVersion = request.protocolVersion
        requestDigestCanonicalizationVersion =
            ForgeFilesystemProtocolConstants.requestDigestCanonicalizationVersion
        expectedLeafIdentity = request.expectedLeafIdentity.map(FilesystemIdentity.init)
        requestDigestSHA256 = request.requestDigestSHA256
        self.parentIdentity = parentIdentity
    }

    var leafName: String { relativePathComponents.last ?? "" }

    var contract: ForgeFilesystemOperationContract? {
        if let contractRawValue {
            return ForgeFilesystemOperationContract(rawValue: contractRawValue)
        }
        // Protocol-v4 records represented only namespace-exact leaf deletion.
        return .namespaceVersionExact
    }

    var isLegacyProtocolFourRecord: Bool {
        schemaVersion == Self.legacyProtocolFourSchema
            && contractRawValue == nil
            && requestProtocolVersion == nil
            && requestDigestCanonicalizationVersion == nil
            && requestDigestSHA256 == nil
            && expectedLeafIdentity != nil
    }

    var isStructurallyValid: Bool {
        (isLegacyProtocolFourRecord || isCurrentProtocolRecord)
            && UUID(uuidString: requestID) != nil
            && UUID(uuidString: transactionID) != nil
            && UUID(uuidString: projectID) != nil
            && projectGeneration > 0
            && projectGeneration <= UInt64(Int64.max)
            && ForgeFilesystemRequesterPolicy.isValidRequesterUID(requesterUID)
            && !rootID.isEmpty
            && rootID.utf8.count <= 128
            && accessRawValue == ForgeFilesystemAccess.deleteLeaf.rawValue
            && contract != nil
            && hasValidPersistedRequestShape
            && !relativePathComponents.isEmpty
            && relativePathComponents.count <= ForgeFilesystemProtocolConstants.maximumRelativeComponents
            && relativePathComponents.allSatisfy { component in
                !component.isEmpty
                    && component != "."
                    && component != ".."
                    && !component.contains("/")
                    && !component.contains("\0")
                    && component.utf8.count <= ForgeFilesystemProtocolConstants.maximumComponentBytes
            }
            && Self.contractFieldsAreValid(
                contract: contract,
                expectedLeafIdentity: expectedLeafIdentity
            )
    }

    private var hasValidPersistedRequestShape: Bool {
        if isLegacyProtocolFourRecord {
            return true
        }
        guard isCurrentProtocolRecord,
              contractRawValue != nil,
              let requestProtocolVersion,
              let requestDigestSHA256,
              Self.isLowercaseSHA256(requestDigestSHA256),
              let access = ForgeFilesystemAccess(rawValue: accessRawValue),
              let contract else {
            return false
        }
        let reconstructed = ForgeFilesystemMutationRequest(
            protocolVersion: requestProtocolVersion,
            requestID: requestID,
            transactionID: transactionID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            rootID: rootID,
            rootIdentity: ForgeFilesystemIdentity(
                device: rootIdentity.device,
                inode: rootIdentity.inode,
                mode: rootIdentity.mode,
                owner: rootIdentity.owner,
                group: rootIdentity.group,
                linkCount: rootIdentity.linkCount
            ),
            relativePathComponents: relativePathComponents,
            access: access,
            contract: contract,
            expectedLeafIdentity: expectedLeafIdentity.map { identity in
                ForgeFilesystemIdentity(
                    device: identity.device,
                    inode: identity.inode,
                    mode: identity.mode,
                    owner: identity.owner,
                    group: identity.group,
                    linkCount: identity.linkCount
                )
            }
        )
        return reconstructed.validationError() == nil
            && reconstructed.requestDigestSHA256 == requestDigestSHA256
    }

    private var isCurrentProtocolRecord: Bool {
        schemaVersion == Self.currentSchema
            && requestProtocolVersion == ForgeFilesystemProtocolConstants.version
            && requestDigestCanonicalizationVersion
                == ForgeFilesystemProtocolConstants.requestDigestCanonicalizationVersion
    }

    func matches(_ request: ForgeFilesystemMutationRequest, requesterUID: uid_t) -> Bool {
        ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            self.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        )
            && requestID.caseInsensitiveCompare(request.requestID) == .orderedSame
            && transactionID.caseInsensitiveCompare(request.transactionID) == .orderedSame
            && projectID.caseInsensitiveCompare(request.projectID) == .orderedSame
            && projectGeneration == request.projectGeneration
            && rootID == request.rootID
            && rootIdentity == FilesystemIdentity(request.rootIdentity)
            && relativePathComponents == request.relativePathComponents
            && accessRawValue == request.accessRawValue
            && contract == request.contract
            && (requestProtocolVersion == nil
                || requestProtocolVersion == request.protocolVersion)
            && (requestDigestCanonicalizationVersion == nil
                || requestDigestCanonicalizationVersion
                    == ForgeFilesystemProtocolConstants.requestDigestCanonicalizationVersion)
            && expectedLeafIdentity == request.expectedLeafIdentity.map(FilesystemIdentity.init)
            && (requestDigestSHA256 == nil
                || requestDigestSHA256 == request.requestDigestSHA256)
    }

    func authorizes(
        _ request: ForgeFilesystemTransactionControlRequest,
        requesterUID: uid_t,
        rootInformation: stat
    ) -> Bool {
        ForgeFilesystemTransactionAuthorityPolicy.matchesPersistedAuthority(
            request: request,
            currentRequesterUID: UInt32(requesterUID),
            persistedRequesterUID: self.requesterUID,
            persistedTransactionID: transactionID,
            persistedProjectID: projectID,
            persistedProjectGeneration: projectGeneration,
            persistedRootID: rootID,
            persistedRootIdentity: ForgeFilesystemIdentity(
                device: rootIdentity.device,
                inode: rootIdentity.inode,
                mode: rootIdentity.mode,
                owner: rootIdentity.owner,
                group: rootIdentity.group,
                linkCount: rootIdentity.linkCount
            )
        )
            && rootIdentity.matchesRoot(rootInformation)
    }

    private static func contractFieldsAreValid(
        contract: ForgeFilesystemOperationContract?,
        expectedLeafIdentity: FilesystemIdentity?
    ) -> Bool {
        switch contract {
        case .currentEntry:
            expectedLeafIdentity == nil
        case .namespaceVersionExact, .contentVersionExact:
            expectedLeafIdentity != nil
        case nil:
            false
        }
    }

    private static func isLowercaseSHA256(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

private struct CapturedLeafReceipt: Codable, Equatable {
    static let currentSchema = 1

    let schemaVersion: Int
    let transactionID: String
    let requestDigestSHA256: String?
    let identity: FilesystemIdentity

    init(record: TransactionRecord, identity: FilesystemIdentity) {
        schemaVersion = Self.currentSchema
        transactionID = record.transactionID.lowercased()
        requestDigestSHA256 = record.requestDigestSHA256
        self.identity = identity
    }

    func isValid(for record: TransactionRecord) -> Bool {
        schemaVersion == Self.currentSchema
            && UUID(uuidString: transactionID) != nil
            && transactionID.caseInsensitiveCompare(record.transactionID) == .orderedSame
            && requestDigestSHA256 == record.requestDigestSHA256
            && identity.inode != 0
            && identity.mode & UInt32(S_IFMT) != 0
    }
}

private struct TransactionTerminalOutcome: Codable, Equatable {
    static let currentSchema = 1

    let schemaVersion: Int
    let transactionID: String
    let disposition: ForgeFilesystemTransactionDisposition
    let ok: Bool
    let code: String
    let message: String
    let committed: Bool
    let durabilityConfirmed: Bool
    let recoveryTransactionID: String
    let acknowledgementRequired: Bool
    let capturedIdentity: FilesystemIdentity?

    init(
        transactionID: String,
        disposition: ForgeFilesystemTransactionDisposition,
        ok: Bool,
        code: String,
        message: String,
        committed: Bool,
        durabilityConfirmed: Bool,
        recoveryTransactionID: String,
        acknowledgementRequired: Bool,
        capturedIdentity: FilesystemIdentity? = nil
    ) {
        schemaVersion = Self.currentSchema
        self.transactionID = transactionID.lowercased()
        self.disposition = disposition
        self.ok = ok
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        self.committed = committed
        self.durabilityConfirmed = durabilityConfirmed
        self.recoveryTransactionID = recoveryTransactionID.lowercased()
        self.acknowledgementRequired = acknowledgementRequired
        self.capturedIdentity = capturedIdentity
    }

    func isValid(for record: TransactionRecord) -> Bool {
        guard schemaVersion == Self.currentSchema,
              UUID(uuidString: transactionID) != nil,
              transactionID.caseInsensitiveCompare(record.transactionID) == .orderedSame,
              recoveryTransactionID.caseInsensitiveCompare(record.transactionID) == .orderedSame,
              !code.isEmpty,
              code.utf8.count <= 128,
              message.utf8.count <= 1_024,
              durabilityConfirmed else {
            return false
        }
        switch disposition {
        case .committed:
            return ok
                && committed
                && code == "ok"
                && acknowledgementRequired
                && (record.requestDigestSHA256 == nil || capturedIdentity != nil)
        case .restored, .rejected, .conflicted:
            return !ok && !committed && code != "ok" && acknowledgementRequired
        case .quarantined:
            return !ok
                && !committed
                && code != "ok"
                && !acknowledgementRequired
                && capturedIdentity != nil
        case .unavailable, .recoveryRequired:
            return false
        }
    }

    var terminalPhase: TransactionPhase {
        switch disposition {
        case .committed: .committed
        case .restored: .rollback
        case .rejected: .intent
        case .quarantined: .rollback
        case .conflicted: .rollback
        case .unavailable, .recoveryRequired: .intent
        }
    }

    func response() -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: ok,
            code: code,
            message: message,
            committed: committed,
            durabilityConfirmed: durabilityConfirmed,
            recoveryTransactionID: recoveryTransactionID,
            acknowledgementRequired: acknowledgementRequired
        )
    }

    func status() -> ForgeFilesystemTransactionStatus {
        ForgeFilesystemTransactionStatus(
            transactionID: transactionID,
            disposition: disposition,
            code: code,
            message: message,
            terminal: true,
            committed: committed,
            durabilityConfirmed: durabilityConfirmed,
            recoveryRequired: disposition == .quarantined,
            acknowledgementRequired: acknowledgementRequired
        )
    }
}

private struct TransactionAcknowledgement: Codable, Equatable {
    static let currentSchema = 1

    let schemaVersion: Int
    let record: TransactionRecord
    let outcome: TransactionTerminalOutcome

    init(record: TransactionRecord, outcome: TransactionTerminalOutcome) {
        schemaVersion = Self.currentSchema
        self.record = record
        self.outcome = outcome
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchema
            && record.isStructurallyValid
            && outcome.isValid(for: record)
    }
}

private enum TransactionPhase: Int, CaseIterable, Comparable {
    case intent
    case captured
    case rollback
    case committed

    var fileName: String {
        switch self {
        case .intent: "intent.json"
        case .captured: "captured.json"
        case .rollback: "rollback.json"
        case .committed: "committed.json"
        }
    }

    var pendingFileName: String { fileName + ".pending" }

    static func < (lhs: TransactionPhase, rhs: TransactionPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct TransactionSlot {
    let index: Int
    let descriptor: OwnedDescriptor?
    let parentDescriptor: Int32?
    let expectedDevice: dev_t?

    init(index: Int, descriptor: OwnedDescriptor) {
        self.index = index
        self.descriptor = descriptor
        parentDescriptor = nil
        expectedDevice = nil
    }

    init(index: Int, parentDescriptor: Int32, expectedDevice: dev_t) {
        self.index = index
        descriptor = nil
        self.parentDescriptor = parentDescriptor
        self.expectedDevice = expectedDevice
    }
}

private struct ActiveTransaction {
    let slot: TransactionSlot
    let phase: TransactionPhase
    let record: TransactionRecord
    let outcome: TransactionTerminalOutcome?
    let acknowledging: Bool
    let recoveryIssue: String?

    init(
        slot: TransactionSlot,
        phase: TransactionPhase,
        record: TransactionRecord,
        outcome: TransactionTerminalOutcome? = nil,
        acknowledging: Bool = false,
        recoveryIssue: String? = nil
    ) {
        self.slot = slot
        self.phase = phase
        self.record = record
        self.outcome = outcome
        self.acknowledging = acknowledging
        self.recoveryIssue = recoveryIssue
    }
}

private struct TransactionInventory {
    let active: [ActiveTransaction]
    let emptySlots: [TransactionSlot]
}

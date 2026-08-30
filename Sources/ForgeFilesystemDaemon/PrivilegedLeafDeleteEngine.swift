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
    private static let maximumBindingBytes = 8 * 1_024

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
                if existing.phase != .committed {
                    try validateProjectBinding(
                        request,
                        requesterUID: requesterUID,
                        rootInformation: rootInformation,
                        bindingsDescriptor: bindings.rawValue
                    )
                }
                return try resume(
                    existing,
                    request: request,
                    rootDescriptor: root.rawValue,
                    requesterUID: requesterUID
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
            _ = try validateLeafForDeletion(
                named: requestedLeafName,
                in: parent.descriptor.rawValue,
                expectedIdentity: FilesystemIdentity(request.expectedLeafIdentity)
            )
            guard !inventory.active.contains(where: {
                $0.phase != .committed
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
            try writePhase(
                .intent,
                record: record,
                slotDescriptor: try requiredDescriptor(for: slot).rawValue
            )
            return try resume(
                ActiveTransaction(slot: slot, phase: .intent, record: record),
                request: request,
                rootDescriptor: root.rawValue,
                requesterUID: requesterUID
            )
        }
    }

    private func validateRequest(_ request: ForgeFilesystemMutationRequest) throws {
        guard request.protocolVersion == ForgeFilesystemProtocolConstants.version,
              request.validationError() == nil,
              request.access == .deleteLeaf,
              UUID(uuidString: request.requestID) != nil,
              UUID(uuidString: request.transactionID) != nil,
              UUID(uuidString: request.projectID) != nil,
              request.projectGeneration > 0,
              !request.rootID.isEmpty,
              !request.exactContentRequired else {
            throw EngineFailure.capability("The filesystem mutation request is unsupported")
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
        _ operation: () throws -> Value
    ) throws -> Value {
        let descriptor = Self.lockName.withCString {
            Darwin.openat(
                namespaceDescriptor,
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
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
        expectedDevice: dev_t
    ) throws -> TransactionInventory {
        var active: [ActiveTransaction] = []
        var emptySlots: [TransactionSlot] = []
        var recyclable: [ActiveTransaction] = []

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
            guard let state = try loadTransaction(from: slot) else {
                emptySlots.append(slot)
                continue
            }
            active.append(state)
            if state.phase == .committed,
               try namedInformationIfExists("leaf", in: descriptor.rawValue) == nil {
                recyclable.append(state)
            }
        }
        recyclable.sort { $0.record.createdAtMilliseconds < $1.record.createdAtMilliseconds }
        return TransactionInventory(
            active: active,
            emptySlots: emptySlots,
            recyclable: recyclable
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
                    throw EngineFailure.capability(
                        "The filesystem transaction identifier conflicts with another request"
                    )
                }
                return transaction
            }
            if transaction.record.requestID.caseInsensitiveCompare(
                request.requestID
            ) == .orderedSame {
                throw EngineFailure.capability(
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
        guard let terminal = inventory.recyclable.first else {
            throw EngineFailure.namespace("The bounded transaction ledger is full")
        }
        try clearTerminalTransaction(terminal)
        return terminal.slot
    }

    private func loadTransaction(from slot: TransactionSlot) throws -> ActiveTransaction? {
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
        guard let selectedRecord, let selectedPhase else {
            if try namedInformationIfExists("leaf", in: slotDescriptor) != nil {
                throw EngineFailure.namespace("An untracked protected leaf requires recovery")
            }
            try removePendingPhaseFiles(slotDescriptor: slotDescriptor)
            return nil
        }
        return ActiveTransaction(slot: slot, phase: selectedPhase, record: selectedRecord)
    }

    private func resume(
        _ transaction: ActiveTransaction,
        request: ForgeFilesystemMutationRequest,
        rootDescriptor: Int32,
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
        let slotDescriptor = try preservingRecoveryIdentity(
            transactionID: request.transactionID
        ) {
            try requiredDescriptor(for: transaction.slot).rawValue
        }
        let protectedInformation = try preservingRecoveryIdentity(
            transactionID: request.transactionID
        ) {
            try namedInformationIfExists("leaf", in: slotDescriptor)
        }

        switch transaction.phase {
        case .committed:
            guard protectedInformation == nil else {
                throw EngineFailure.namespace(
                    "A committed transaction retains a protected leaf",
                    recoveryTransactionID: request.transactionID
                )
            }
            return success()

        case .captured:
            if protectedInformation == nil {
                do {
                    try synchronize(slotDescriptor)
                    try writePhase(
                        .committed,
                        record: transaction.record,
                        slotDescriptor: slotDescriptor
                    )
                } catch {
                    throw EngineFailure.namespace(
                        "The terminal deletion is present without a durable committed receipt",
                        committed: true,
                        recoveryTransactionID: request.transactionID
                    )
                }
                return success()
            }
            return try preservingRecoveryIdentity(
                transactionID: request.transactionID
            ) {
                guard (try? validateLeafForDeletion(
                    named: "leaf",
                    in: slotDescriptor,
                    expectedIdentity: transaction.record.expectedLeafIdentity
                )) != nil else {
                    return try rollbackCapturedLeaf(
                        transaction,
                        request: request,
                        rootDescriptor: rootDescriptor,
                        requesterUID: requesterUID
                    )
                }
                return try terminalUnlink(
                    transaction,
                    request: request,
                    requesterUID: requesterUID
                )
            }

        case .rollback:
            return try preservingRecoveryIdentity(
                transactionID: request.transactionID
            ) {
                guard protectedInformation != nil else {
                    let parent = try reopenRecordedParent(
                        transaction.record,
                        rootDescriptor: rootDescriptor,
                        requesterUID: requesterUID
                    )
                    _ = try validateLeafForDeletion(
                        named: transaction.record.leafName,
                        in: parent.descriptor.rawValue,
                        expectedIdentity: transaction.record.expectedLeafIdentity
                    )
                    try synchronize(parent.descriptor.rawValue)
                    try synchronize(slotDescriptor)
                    try clearUncommittedTransaction(transaction)
                    return failure(
                        code: ForgeFilesystemErrorCode.capabilityUnavailable,
                        message: "The captured filesystem leaf was restored",
                        durabilityConfirmed: true
                    )
                }
                return try rollbackCapturedLeaf(
                    transaction,
                    request: request,
                    rootDescriptor: rootDescriptor,
                    requesterUID: requesterUID
                )
            }

        case .intent:
            if protectedInformation != nil {
                return try preservingRecoveryIdentity(
                    transactionID: request.transactionID
                ) {
                    guard (try? validateLeafForDeletion(
                        named: "leaf",
                        in: slotDescriptor,
                        expectedIdentity: transaction.record.expectedLeafIdentity
                    )) != nil else {
                        return try rollbackCapturedLeaf(
                            transaction,
                            request: request,
                            rootDescriptor: rootDescriptor,
                            requesterUID: requesterUID
                        )
                    }
                    let parent = try reopenRecordedParent(
                        transaction.record,
                        rootDescriptor: rootDescriptor,
                        requesterUID: requesterUID
                    )
                    guard try namedInformationIfExists(
                        transaction.record.leafName,
                        in: parent.descriptor.rawValue
                    ) == nil else {
                        return try rollbackCapturedLeaf(
                            transaction,
                            request: request,
                            rootDescriptor: rootDescriptor,
                            requesterUID: requesterUID
                        )
                    }
                    try synchronize(parent.descriptor.rawValue)
                    try synchronize(slotDescriptor)
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
                        request: request,
                        requesterUID: requesterUID
                    )
                }
            }

            let parent = try preservingRecoveryIdentity(
                transactionID: request.transactionID
            ) {
                try reopenRecordedParent(
                    transaction.record,
                    rootDescriptor: rootDescriptor,
                    requesterUID: requesterUID
                )
            }
            let sourceInformation = try preservingRecoveryIdentity(
                transactionID: request.transactionID
            ) {
                try namedInformationIfExists(
                    transaction.record.leafName,
                    in: parent.descriptor.rawValue
                )
            }
            guard sourceInformation != nil else {
                try preservingRecoveryIdentity(transactionID: request.transactionID) {
                    try clearUncommittedTransaction(transaction)
                }
                return failure(
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "The requested filesystem leaf is absent",
                    durabilityConfirmed: true
                )
            }
            do {
                _ = try validateLeafForDeletion(
                    named: transaction.record.leafName,
                    in: parent.descriptor.rawValue,
                    expectedIdentity: transaction.record.expectedLeafIdentity
                )
            } catch {
                try preservingRecoveryIdentity(transactionID: request.transactionID) {
                    try clearUncommittedTransaction(transaction)
                }
                return failure(
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "The requested leaf is not eligible for requester-authorized deletion",
                    durabilityConfirmed: true
                )
            }
            return try preservingRecoveryIdentity(
                transactionID: request.transactionID
            ) {
                try captureAndDelete(
                    transaction,
                    request: request,
                    parent: parent,
                    requesterUID: requesterUID
                )
            }
        }
    }

    private func preservingRecoveryIdentity<Result>(
        transactionID: String,
        _ operation: () throws -> Result
    ) throws -> Result {
        do {
            return try operation()
        } catch let failure as EngineFailure {
            guard failure.recoveryTransactionID == nil else { throw failure }
            throw EngineFailure(
                code: failure.code,
                message: failure.message,
                committed: failure.committed,
                durabilityConfirmed: failure.durabilityConfirmed,
                recoveryTransactionID: transactionID
            )
        } catch {
            throw EngineFailure.namespace(
                "The protected filesystem transaction requires recovery",
                recoveryTransactionID: transactionID
            )
        }
    }

    private func captureAndDelete(
        _ transaction: ActiveTransaction,
        request: ForgeFilesystemMutationRequest,
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
            let code = errno
            if code == EXDEV {
                try clearUncommittedTransaction(transaction)
                return failure(
                    code: ForgeFilesystemErrorCode.volumeUnqualified,
                    message: "The protected namespace is not on the source volume",
                    durabilityConfirmed: true
                )
            }
            if code == ENOENT {
                do {
                    try clearUncommittedTransaction(transaction)
                } catch {
                    throw EngineFailure.namespace(
                        "The changed source namespace has a retained intent receipt",
                        recoveryTransactionID: request.transactionID
                    )
                }
                return failure(
                    code: ForgeFilesystemErrorCode.capabilityUnavailable,
                    message: "The requested filesystem namespace changed",
                    durabilityConfirmed: true
                )
            }
            if code == EEXIST {
                throw EngineFailure.namespace(
                    "The protected capture slot is unexpectedly occupied",
                    recoveryTransactionID: request.transactionID
                )
            }
            throw EngineFailure.namespace(
                "The protected atomic capture failed",
                recoveryTransactionID: request.transactionID
            )
        }

        let capturedInformation = try? validateLeafForDeletion(
            named: "leaf",
            in: slotDescriptor,
            expectedIdentity: transaction.record.expectedLeafIdentity
        )
        let namespaceStable = (try? requestedNamespaceIsStable(
            transaction.record,
            rootDescriptor: parent.rootDescriptor,
            requesterUID: requesterUID
        )) ?? false
        guard capturedInformation != nil,
              namespaceStable else {
            return try rollbackCapturedLeaf(
                transaction,
                request: request,
                rootDescriptor: parent.rootDescriptor,
                requesterUID: requesterUID,
                fallbackParent: parent
            )
        }

        do {
            try synchronize(parent.descriptor.rawValue)
            try synchronize(slotDescriptor)
            try writePhase(
                .captured,
                record: transaction.record,
                slotDescriptor: slotDescriptor
            )
        } catch {
            throw EngineFailure.namespace(
                "The protected capture requires recovery before deletion",
                recoveryTransactionID: request.transactionID
            )
        }
        return try terminalUnlink(
            ActiveTransaction(
                slot: transaction.slot,
                phase: .captured,
                record: transaction.record
            ),
            request: request,
            requesterUID: requesterUID
        )
    }

    private func terminalUnlink(
        _ transaction: ActiveTransaction,
        request: ForgeFilesystemMutationRequest,
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
        guard (try? validateLeafForDeletion(
            named: "leaf",
            in: descriptor,
            expectedIdentity: transaction.record.expectedLeafIdentity
        )) != nil else {
            throw EngineFailure.namespace(
                "The protected leaf identity, ACL, or flags changed before terminal deletion",
                recoveryTransactionID: request.transactionID
            )
        }

        // Quarantine and identity revalidation mitigate namespace replacement, but do
        // not eliminate content changes through an already-open writable descriptor or
        // a hard link. Exact-content deletion is therefore deliberately unsupported.
        guard "leaf".withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
            throw EngineFailure.namespace(
                "The protected leaf could not be deleted",
                recoveryTransactionID: request.transactionID
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
                recoveryTransactionID: request.transactionID
            )
        }
        return success()
    }

    private func rollbackCapturedLeaf(
        _ transaction: ActiveTransaction,
        request: ForgeFilesystemMutationRequest,
        rootDescriptor: Int32,
        requesterUID: uid_t,
        fallbackParent: SourceParent? = nil
    ) throws -> ForgeFilesystemResponse {
        guard ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            transaction.record.requesterUID,
            currentRequesterUID: UInt32(requesterUID)
        ) else {
            throw EngineFailure.capability(
                "The filesystem transaction belongs to a different requester"
            )
        }
        let parent: SourceParent
        do {
            parent = try reopenRecordedParent(
                transaction.record,
                rootDescriptor: rootDescriptor,
                requesterUID: requesterUID
            )
        } catch {
            guard let fallbackParent,
                  transaction.record.parentIdentity.matchesRoot(fallbackParent.information) else {
                throw EngineFailure.namespace(
                    "The captured leaf cannot be restored to its recorded parent",
                    recoveryTransactionID: request.transactionID
                )
            }
            parent = fallbackParent
        }

        let slotDescriptor = try requiredDescriptor(for: transaction.slot).rawValue
        try writePhase(
            .rollback,
            record: transaction.record,
            slotDescriptor: slotDescriptor
        )
        let result = "leaf".withCString { sourceName in
            transaction.record.leafName.withCString { destinationName in
                Darwin.renameatx_np(
                    slotDescriptor,
                    sourceName,
                    parent.descriptor.rawValue,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw EngineFailure.namespace(
                "The captured leaf is retained for exclusive recovery",
                recoveryTransactionID: request.transactionID
            )
        }
        do {
            try synchronize(parent.descriptor.rawValue)
            try synchronize(slotDescriptor)
            try clearUncommittedTransaction(transaction)
        } catch {
            throw EngineFailure.namespace(
                "The restored leaf has a retained recovery receipt",
                recoveryTransactionID: request.transactionID
            )
        }
        return failure(
            code: ForgeFilesystemErrorCode.capabilityUnavailable,
            message: "The requested filesystem namespace or identity changed",
            durabilityConfirmed: true
        )
    }

    private func requestedNamespaceIsStable(
        _ record: TransactionRecord,
        rootDescriptor: Int32,
        requesterUID: uid_t
    ) throws -> Bool {
        let reopened = try reopenRecordedParent(
            record,
            rootDescriptor: rootDescriptor,
            requesterUID: requesterUID
        )
        return try namedInformationIfExists(record.leafName, in: reopened.descriptor.rawValue) == nil
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
            rootDescriptor: rootDescriptor,
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

    private func validateLeafForDeletion(
        named name: String,
        in parentDescriptor: Int32,
        expectedIdentity: FilesystemIdentity
    ) throws -> stat {
        let named = try namedInformation(name, in: parentDescriptor)
        guard ForgeFilesystemRequesterPolicy.permitsLeafType(mode: expectedIdentity.mode),
              ForgeFilesystemRequesterPolicy.permitsLeafType(mode: UInt32(named.st_mode)),
              expectedIdentity.matches(named) else {
            throw EngineFailure.capability(
                "Only the expected regular file or symbolic link is eligible for protected deletion"
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
        guard expectedIdentity.matches(leafInformation),
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

    private func clearUncommittedTransaction(_ transaction: ActiveTransaction) throws {
        let descriptor = try requiredDescriptor(for: transaction.slot).rawValue
        guard try namedInformationIfExists("leaf", in: descriptor) == nil else {
            throw EngineFailure.namespace("A protected leaf prevents receipt cleanup")
        }
        try removePhaseFiles(in: descriptor)
    }

    private func clearTerminalTransaction(_ transaction: ActiveTransaction) throws {
        guard transaction.phase == .committed else {
            throw EngineFailure.namespace("Only terminal transactions can be recycled")
        }
        try clearUncommittedTransaction(transaction)
    }

    private func removePhaseFiles(in descriptor: Int32) throws {
        for phase in TransactionPhase.allCases {
            try unlinkIfExists(phase.pendingFileName, in: descriptor)
            try unlinkIfExists(phase.fileName, in: descriptor)
        }
        try synchronize(descriptor)
    }

    private func removePendingPhaseFiles(slotDescriptor: Int32) throws {
        for phase in TransactionPhase.allCases {
            try unlinkIfExists(phase.pendingFileName, in: slotDescriptor)
        }
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

    private func success() -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "The protected filesystem leaf was deleted",
            committed: true,
            durabilityConfirmed: true
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

    static func volume(_ message: String) -> EngineFailure {
        EngineFailure(
            code: ForgeFilesystemErrorCode.volumeUnqualified,
            message: message,
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
    let rootDescriptor: Int32
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
    static let currentSchema = 2

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
    let expectedLeafIdentity: FilesystemIdentity
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
        expectedLeafIdentity = FilesystemIdentity(request.expectedLeafIdentity)
        self.parentIdentity = parentIdentity
    }

    var leafName: String { relativePathComponents.last ?? "" }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchema
            && UUID(uuidString: requestID) != nil
            && UUID(uuidString: transactionID) != nil
            && UUID(uuidString: projectID) != nil
            && projectGeneration > 0
            && ForgeFilesystemRequesterPolicy.isValidRequesterUID(requesterUID)
            && !rootID.isEmpty
            && accessRawValue == ForgeFilesystemAccess.deleteLeaf.rawValue
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
            && expectedLeafIdentity == FilesystemIdentity(request.expectedLeafIdentity)
            && !request.exactContentRequired
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
}

private struct TransactionInventory {
    let active: [ActiveTransaction]
    let emptySlots: [TransactionSlot]
    let recyclable: [ActiveTransaction]
}

import Darwin
import Foundation
import ForgeFilesystemProtocol
import ServiceManagement

public enum SecureFilesystemServiceStatus: String, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
}

/// The single operator-owned Settings operation that may interact with the
/// protected filesystem service at a time.
public enum SecureFilesystemSettingsOperation: String, CaseIterable, Sendable {
    case bootstrap
    case enable
    case update
    case disable
    case lifecycleRecovery = "lifecycle_recovery"
    case approval
    case refresh
    case reconcile

    public var accessibilityLabel: String {
        switch self {
        case .bootstrap: "Checking protected filesystem service lifecycle"
        case .enable: "Enabling protected filesystem service"
        case .update: "Updating protected filesystem service"
        case .disable: "Disabling protected filesystem service"
        case .lifecycleRecovery: "Resolving interrupted protected filesystem lifecycle"
        case .approval: "Opening protected filesystem approval settings"
        case .refresh: "Refreshing protected filesystem service status"
        case .reconcile: "Reconciling protected filesystem recovery"
        }
    }

    public var mayAwaitServiceUnregister: Bool {
        switch self {
        case .bootstrap, .enable, .update, .disable, .lifecycleRecovery: true
        case .approval, .refresh, .reconcile: false
        }
    }
}

public enum SecureFilesystemServiceLifecyclePhase: String, Sendable {
    case checking
    case settled
    case registering
    case unregistering
    case registrationPending = "registration_pending"
    case outcomeUncertain = "outcome_uncertain"
    case stateInvalid = "state_invalid"
}

public enum SecureFilesystemServiceLifecycleIntent: String, Sendable {
    case enable
    case update
    case disable
}

/// Observable projection of the durable ServiceManagement lifecycle fence.
/// Any state except `settled` blocks a new registration or unregister request.
public struct SecureFilesystemServiceLifecycleState: Sendable, Equatable {
    public let phase: SecureFilesystemServiceLifecyclePhase
    public let intent: SecureFilesystemServiceLifecycleIntent?
    public let operationID: String?

    public init(
        phase: SecureFilesystemServiceLifecyclePhase,
        intent: SecureFilesystemServiceLifecycleIntent? = nil,
        operationID: String? = nil
    ) {
        self.phase = phase
        self.intent = intent
        self.operationID = operationID
    }

    public static let checking = SecureFilesystemServiceLifecycleState(phase: .checking)
    public static let settled = SecureFilesystemServiceLifecycleState(phase: .settled)

    public static func cancelled(
        intent: SecureFilesystemServiceLifecycleIntent?
    ) -> SecureFilesystemServiceLifecycleState {
        SecureFilesystemServiceLifecycleState(
            phase: .outcomeUncertain,
            intent: intent
        )
    }

    public var blocksLifecycleMutation: Bool { phase != .settled }

    public var canRetryResolution: Bool {
        switch phase {
        case .registering, .unregistering, .registrationPending, .outcomeUncertain:
            true
        case .checking, .settled, .stateInvalid:
            false
        }
    }

    public var operatorStatusLabel: String {
        switch phase {
        case .checking:
            "Checking durable lifecycle state"
        case .settled:
            "Settled"
        case .registering:
            "Waiting for macOS to finish registering the service"
        case .unregistering:
            "Waiting for macOS to finish stopping the service"
        case .registrationPending:
            "Service stopped; replacement registration is pending"
        case .outcomeUncertain:
            "Lifecycle outcome uncertain; lifecycle changes are blocked"
        case .stateInvalid:
            "Lifecycle fence invalid; lifecycle changes are blocked"
        }
    }

    public var recoveryActionLabel: String {
        switch phase {
        case .registering:
            "Resume pending registration"
        case .registrationPending:
            "Register pending replacement"
        case .unregistering, .outcomeUncertain:
            "Resume pending lifecycle change"
        case .checking, .settled, .stateInvalid:
            "Resume lifecycle change"
        }
    }
}

/// Identifies one UI-observed lifecycle operation. The independent generation
/// and UUID prevent a late callback from an older operation from overwriting a
/// newer Settings state.
public struct SecureFilesystemServiceLifecycleObservationContext:
    Sendable,
    Equatable
{
    public let generation: UInt64
    public let operationID: UUID

    public init(generation: UInt64, operationID: UUID = UUID()) {
        self.generation = generation
        self.operationID = operationID
    }
}

public struct SecureFilesystemServiceLifecycleObservation: Sendable, Equatable {
    public let context: SecureFilesystemServiceLifecycleObservationContext
    public let state: SecureFilesystemServiceLifecycleState

    public init(
        context: SecureFilesystemServiceLifecycleObservationContext,
        state: SecureFilesystemServiceLifecycleState
    ) {
        self.context = context
        self.state = state
    }
}

/// A single-slot, generation-fenced projection gate for the native Settings
/// surface. It accepts forward progress for only the newest observed operation;
/// no queue or history is retained.
public struct SecureFilesystemServiceLifecycleObservationGate: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var activeContext:
        SecureFilesystemServiceLifecycleObservationContext?
    private var acceptedPhaseRank = -1

    public init() {}

    public mutating func begin()
        -> SecureFilesystemServiceLifecycleObservationContext?
    {
        guard generation < UInt64.max else { return nil }
        generation += 1
        let context = SecureFilesystemServiceLifecycleObservationContext(
            generation: generation
        )
        activeContext = context
        acceptedPhaseRank = -1
        return context
    }

    public mutating func accept(
        _ observation: SecureFilesystemServiceLifecycleObservation
    ) -> SecureFilesystemServiceLifecycleState? {
        guard observation.context == activeContext else { return nil }
        let rank = Self.rank(of: observation.state.phase)
        guard rank >= acceptedPhaseRank else { return nil }
        acceptedPhaseRank = rank
        return observation.state
    }

    private static func rank(of phase: SecureFilesystemServiceLifecyclePhase) -> Int {
        switch phase {
        case .checking: 0
        case .unregistering: 1
        case .outcomeUncertain: 2
        case .registrationPending: 3
        case .registering: 4
        case .settled: 5
        case .stateInvalid: 6
        }
    }
}

/// A bounded, generation-fenced single-operation gate for the native Settings
/// surface. The generation prevents a cancelled task from completing a newer
/// operation of the same kind.
public struct SecureFilesystemSettingsOperationState: Sendable, Equatable {
    public private(set) var activeOperation: SecureFilesystemSettingsOperation?
    public private(set) var generation: UInt64

    public init(
        activeOperation: SecureFilesystemSettingsOperation? = nil,
        generation: UInt64 = 0
    ) {
        self.activeOperation = activeOperation
        self.generation = generation
    }

    public var isActive: Bool { activeOperation != nil }

    @discardableResult
    public mutating func begin(_ operation: SecureFilesystemSettingsOperation) -> UInt64? {
        guard activeOperation == nil, generation < UInt64.max else { return nil }
        generation += 1
        activeOperation = operation
        return generation
    }

    public func owns(
        _ operation: SecureFilesystemSettingsOperation,
        generation expectedGeneration: UInt64
    ) -> Bool {
        activeOperation == operation && generation == expectedGeneration
    }

    @discardableResult
    public mutating func finish(
        _ operation: SecureFilesystemSettingsOperation,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard owns(operation, generation: expectedGeneration) else { return false }
        activeOperation = nil
        return true
    }

    public mutating func cancel() {
        guard activeOperation != nil else { return }
        activeOperation = nil
        if generation < UInt64.max {
            generation += 1
        }
    }
}

/// Computes every control from the same operation gate so no lifecycle,
/// approval, observation, or recovery command can overlap another.
public struct SecureFilesystemSettingsControlAvailability: Sendable, Equatable {
    public let enable: Bool
    public let update: Bool
    public let disable: Bool
    public let approval: Bool
    public let refresh: Bool
    public let reconcile: Bool
    public let lifecycleRecovery: Bool

    public init(
        registrationStatus: SecureFilesystemServiceStatus,
        operationState: SecureFilesystemSettingsOperationState,
        lifecycleState: SecureFilesystemServiceLifecycleState = .settled
    ) {
        guard !operationState.isActive else {
            enable = false
            update = false
            disable = false
            approval = false
            refresh = false
            reconcile = false
            lifecycleRecovery = false
            return
        }

        guard !lifecycleState.blocksLifecycleMutation else {
            enable = false
            update = false
            disable = false
            approval = false
            refresh = lifecycleState.phase != .checking
            reconcile = false
            lifecycleRecovery = lifecycleState.canRetryResolution
            return
        }

        enable = registrationStatus != .enabled
        update = registrationStatus != .notFound
        disable = registrationStatus != .notRegistered
            && registrationStatus != .notFound
        approval = true
        refresh = true
        reconcile = true
        lifecycleRecovery = false
    }
}

public enum SecureFilesystemServiceOperationalState: String, Sendable {
    case notPackaged = "not_packaged"
    case notRegistered = "not_registered"
    case requiresApproval = "requires_approval"
    case registeredUnavailable = "registered_unavailable"
    case operational
}

public struct SecureFilesystemOperationalHealth: Sendable, Equatable {
    public let registrationStatus: SecureFilesystemServiceStatus
    public let operationalState: SecureFilesystemServiceOperationalState
    public let localQuarantineOccupied: Int
    public let localQuarantineCapacity: Int
    public let privilegedRecoveryRetained: Int
    public let privilegedRecoveryCapacity: Int
    public let releasedDuringReconciliation: Int
    public let debtStatusAvailable: Bool

    public init(
        registrationStatus: SecureFilesystemServiceStatus,
        operationalState: SecureFilesystemServiceOperationalState,
        localQuarantineOccupied: Int,
        localQuarantineCapacity: Int,
        privilegedRecoveryRetained: Int,
        privilegedRecoveryCapacity: Int,
        releasedDuringReconciliation: Int,
        debtStatusAvailable: Bool
    ) {
        self.registrationStatus = registrationStatus
        self.operationalState = operationalState
        self.localQuarantineOccupied = localQuarantineOccupied
        self.localQuarantineCapacity = localQuarantineCapacity
        self.privilegedRecoveryRetained = privilegedRecoveryRetained
        self.privilegedRecoveryCapacity = privilegedRecoveryCapacity
        self.releasedDuringReconciliation = releasedDuringReconciliation
        self.debtStatusAvailable = debtStatusAvailable
    }

    public static let initial = SecureFilesystemOperationalHealth(
        registrationStatus: .notFound,
        operationalState: .notPackaged,
        localQuarantineOccupied: 0,
        localQuarantineCapacity: 32,
        privilegedRecoveryRetained: 0,
        privilegedRecoveryCapacity: 32,
        releasedDuringReconciliation: 0,
        debtStatusAvailable: false
    )

    public var unresolvedDebtCount: Int {
        localQuarantineOccupied + privilegedRecoveryRetained
    }

    public var hasExhaustedLedger: Bool {
        localQuarantineOccupied >= localQuarantineCapacity
            || privilegedRecoveryRetained >= privilegedRecoveryCapacity
    }
}

struct SecureFilesystemServiceOperationalProbe: Sendable, Equatable {
    let operational: Bool
    let code: String
    let message: String
}

struct SecureFilesystemRecoveryReconciliation: Sendable, Equatable {
    let retainedCount: Int
    let releasedCount: Int
    let available: Bool

    static let unavailable = SecureFilesystemRecoveryReconciliation(
        retainedCount: 0,
        releasedCount: 0,
        available: false
    )
}

public enum SecureFilesystemServiceLifecycleError: LocalizedError, Sendable {
    case superseded
    case registerTimedOut
    case unregisterTimedOut
    case lifecycleResolutionRequired
    case lifecycleStateInvalid

    public var errorDescription: String? {
        switch self {
        case .superseded:
            "The protected filesystem service lifecycle attempt was superseded"
        case .registerTimedOut:
            "The protected filesystem service did not finish registering before the lifecycle timeout"
        case .unregisterTimedOut:
            "The protected filesystem service did not finish stopping before the lifecycle timeout"
        case .lifecycleResolutionRequired:
            "A previous protected filesystem service lifecycle change is unresolved; resolve it before another lifecycle change"
        case .lifecycleStateInvalid:
            "The protected filesystem service lifecycle fence is unavailable or invalid; lifecycle changes remain blocked"
        }
    }
}

private enum SecureFilesystemServiceLifecycleRecordPhase: String, Codable, Sendable {
    case registering
    case unregistering
    case registrationPending = "registration_pending"
    case outcomeUncertain = "outcome_uncertain"
}

private struct SecureFilesystemServiceLifecycleRecord: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let operationID: String
    let attemptID: String
    let intent: String
    let phase: SecureFilesystemServiceLifecycleRecordPhase
    let attemptNumber: Int?
    let leaseDevice: UInt64?
    let leaseInode: UInt64?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64

    var normalizedAttemptNumber: Int { attemptNumber ?? 1 }

    var projectedState: SecureFilesystemServiceLifecycleState? {
        guard (1...2).contains(schemaVersion),
              UUID(uuidString: operationID) != nil,
              UUID(uuidString: attemptID) != nil,
              let lifecycleIntent = SecureFilesystemServiceLifecycleIntent(rawValue: intent),
              (1...SecureFilesystemServiceLifecycleFenceStore.maximumAttempts)
                .contains(normalizedAttemptNumber),
              hasValidIntentAndPhase(lifecycleIntent),
              hasValidLeaseIdentity,
              createdAtMilliseconds >= 0,
              updatedAtMilliseconds >= createdAtMilliseconds else {
            return nil
        }
        let publicPhase: SecureFilesystemServiceLifecyclePhase
        switch phase {
        case .registering:
            publicPhase = .registering
        case .unregistering:
            publicPhase = .unregistering
        case .registrationPending:
            publicPhase = .registrationPending
        case .outcomeUncertain:
            publicPhase = .outcomeUncertain
        }
        return SecureFilesystemServiceLifecycleState(
            phase: publicPhase,
            intent: lifecycleIntent,
            operationID: operationID
        )
    }

    private var hasValidLeaseIdentity: Bool {
        switch (leaseDevice, leaseInode) {
        case (nil, nil):
            return schemaVersion == 1
        case (.some, .some):
            return schemaVersion == 2
        default:
            return false
        }
    }

    private func hasValidIntentAndPhase(
        _ lifecycleIntent: SecureFilesystemServiceLifecycleIntent
    ) -> Bool {
        switch (lifecycleIntent, phase) {
        case (.enable, .registering):
            true
        case (.disable, .unregistering), (.disable, .outcomeUncertain):
            true
        case (.update, _):
            true
        default:
            false
        }
    }
}

private enum SecureFilesystemServiceLifecycleRecoveryAction: Sendable {
    case register
    case unregister
}

/// A descriptor-backed lease is retained through the complete ServiceManagement
/// side effect. Process death releases `flock` automatically; timeout and task
/// cancellation deliberately do not. The durable record identifies the exact
/// lock inode so replacing the lock pathname cannot silently authorize recovery.
private final class SecureFilesystemServiceLifecycleLease: @unchecked Sendable {
    let device: UInt64?
    let inode: UInt64?

    private let stateLock = NSLock()
    private var descriptor: Int32?
    private var memoryRelease: (@Sendable () -> Void)?
    private let lockURL: URL?

    init(
        descriptor: Int32,
        information: stat,
        lockURL: URL
    ) {
        self.descriptor = descriptor
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
        self.lockURL = lockURL
    }

    init(memoryRelease: @escaping @Sendable () -> Void) {
        descriptor = nil
        // The in-memory test seam still uses a schema-v2 record. A stable
        // sentinel identity keeps its exact-attempt validation equivalent to
        // the descriptor-backed path without pretending it is a filesystem
        // inode.
        device = 0
        inode = 0
        lockURL = nil
        self.memoryRelease = memoryRelease
    }

    func validateLinkedIdentity() throws {
        stateLock.lock()
        let activeDescriptor = descriptor
        let release = memoryRelease
        let expectedURL = lockURL
        stateLock.unlock()

        if release != nil { return }
        guard let activeDescriptor, let expectedURL else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        var descriptorInformation = stat()
        var pathInformation = stat()
        guard Darwin.fstat(activeDescriptor, &descriptorInformation) == 0,
              expectedURL.path.withCString({ Darwin.lstat($0, &pathInformation) }) == 0,
              descriptorInformation.st_mode & S_IFMT == S_IFREG,
              descriptorInformation.st_uid == geteuid(),
              descriptorInformation.st_nlink == 1,
              descriptorInformation.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR),
              pathInformation.st_dev == descriptorInformation.st_dev,
              pathInformation.st_ino == descriptorInformation.st_ino else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
    }

    func release() {
        stateLock.lock()
        let descriptorToClose = descriptor
        let releaseMemory = memoryRelease
        descriptor = nil
        memoryRelease = nil
        stateLock.unlock()

        if let descriptorToClose {
            _ = flock(descriptorToClose, LOCK_UN)
            _ = Darwin.close(descriptorToClose)
        }
        releaseMemory?()
    }

    deinit { release() }
}

private final class SecureFilesystemServiceMemoryLeaseCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var activeToken: UUID?

    func acquire() throws -> SecureFilesystemServiceLifecycleLease {
        lock.lock()
        guard activeToken == nil else {
            lock.unlock()
            throw SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired
        }
        let token = UUID()
        activeToken = token
        lock.unlock()
        return SecureFilesystemServiceLifecycleLease { [weak self] in
            self?.release(token: token)
        }
    }

    private func release(token: UUID) {
        lock.lock()
        if activeToken == token { activeToken = nil }
        lock.unlock()
    }
}

private struct SecureFilesystemServiceLifecycleAttempt: @unchecked Sendable {
    let record: SecureFilesystemServiceLifecycleRecord
    let lease: SecureFilesystemServiceLifecycleLease
}

private struct SecureFilesystemServiceLifecycleRecovery: @unchecked Sendable {
    let attempt: SecureFilesystemServiceLifecycleAttempt
    let action: SecureFilesystemServiceLifecycleRecoveryAction
}

/// Serializes the lifecycle fence off the main actor and keeps one stable lease
/// across every ServiceManagement mutation. Record replacement remains an E2
/// namespace risk; exact attempt and lease-inode checks mitigate it but do not
/// claim identity-conditional mutation against a hostile same-UID peer.
private actor SecureFilesystemServiceLifecycleFenceStore {
    static let maximumAttempts = 8
    private static let maximumRecordBytes = 4 * 1_024
    private let recordURL: URL?
    private let memoryLeaseCoordinator = SecureFilesystemServiceMemoryLeaseCoordinator()
    private var inMemoryRecord: SecureFilesystemServiceLifecycleRecord?
    private var integrityFailure = false
    private var internallyReconciledAttemptID: String?

    init(recordURL: URL? = nil) {
        self.recordURL = recordURL
    }

    func state() -> SecureFilesystemServiceLifecycleState {
        guard !integrityFailure else {
            return SecureFilesystemServiceLifecycleState(phase: .stateInvalid)
        }
        do {
            guard let record = try validatedRecordUnlocked() else { return .settled }
            try validateRecordedLeaseIdentity(record, allowingLegacyRecord: true)
            return record.projectedState
                ?? SecureFilesystemServiceLifecycleState(phase: .stateInvalid)
        } catch {
            return SecureFilesystemServiceLifecycleState(phase: .stateInvalid)
        }
    }

    func begin(
        intent: SecureFilesystemServiceLifecycleIntent,
        phase: SecureFilesystemServiceLifecycleRecordPhase
    ) throws -> SecureFilesystemServiceLifecycleAttempt {
        let lease = try acquireLease()
        do {
            guard !integrityFailure else {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
            internallyReconciledAttemptID = nil
            guard try validatedRecordUnlocked() == nil else {
                throw SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired
            }
            let now = Self.nowMilliseconds()
            let record = SecureFilesystemServiceLifecycleRecord(
                schemaVersion: 2,
                operationID: UUID().uuidString.lowercased(),
                attemptID: UUID().uuidString.lowercased(),
                intent: intent.rawValue,
                phase: phase,
                attemptNumber: 1,
                leaseDevice: lease.device,
                leaseInode: lease.inode,
                createdAtMilliseconds: now,
                updatedAtMilliseconds: now
            )
            try persistUnlocked(record)
            return SecureFilesystemServiceLifecycleAttempt(record: record, lease: lease)
        } catch {
            lease.release()
            throw error
        }
    }

    func prepareRecovery() throws -> SecureFilesystemServiceLifecycleRecovery? {
        let lease = try acquireLease()
        do {
            guard !integrityFailure else {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
            internallyReconciledAttemptID = nil
            guard let existing = try validatedRecordUnlocked() else {
                lease.release()
                return nil
            }
            try validateRecordedLeaseIdentity(existing, allowingLegacyRecord: true)
            guard existing.normalizedAttemptNumber < Self.maximumAttempts else {
                throw SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired
            }
            let action: SecureFilesystemServiceLifecycleRecoveryAction
            let phase: SecureFilesystemServiceLifecycleRecordPhase
            switch existing.phase {
            case .registering, .registrationPending:
                action = .register
                phase = .registering
            case .unregistering, .outcomeUncertain:
                action = .unregister
                phase = .unregistering
            }
            let recovered = replacing(
                existing,
                attemptID: UUID().uuidString.lowercased(),
                phase: phase,
                attemptNumber: existing.normalizedAttemptNumber + 1,
                lease: lease
            )
            try persistUnlocked(recovered)
            return SecureFilesystemServiceLifecycleRecovery(
                attempt: SecureFilesystemServiceLifecycleAttempt(
                    record: recovered,
                    lease: lease
                ),
                action: action
            )
        } catch {
            lease.release()
            throw error
        }
    }

    func requireCurrent(_ attempt: SecureFilesystemServiceLifecycleAttempt) throws {
        _ = try exactRecordUnlocked(for: attempt)
    }

    func transition(
        _ attempt: SecureFilesystemServiceLifecycleAttempt,
        to phase: SecureFilesystemServiceLifecycleRecordPhase
    ) throws -> SecureFilesystemServiceLifecycleAttempt {
        let existing = try exactRecordUnlocked(for: attempt)
        let next = replacing(existing, phase: phase, lease: attempt.lease)
        try persistUnlocked(next)
        return SecureFilesystemServiceLifecycleAttempt(record: next, lease: attempt.lease)
    }

    func markUncertain(_ attempt: SecureFilesystemServiceLifecycleAttempt) throws {
        if internallyReconciledAttemptID == attempt.record.attemptID {
            internallyReconciledAttemptID = nil
            return
        }
        let existing = try exactRecordUnlocked(for: attempt)
        guard existing.phase == .unregistering else {
            integrityFailure = true
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        try persistUnlocked(replacing(
            existing,
            phase: .outcomeUncertain,
            lease: attempt.lease
        ))
    }

    /// Reconciles a callback that arrived after timeout/cancellation had already
    /// won the caller completion race. The bounded in-memory tombstone makes
    /// callback-first and uncertainty-first actor scheduling equivalent while
    /// preserving fail-closed behavior for an externally removed record.
    func reconcileLateUnregisterCallback(
        _ attempt: SecureFilesystemServiceLifecycleAttempt,
        registrationAfterSuccess: Bool,
        succeeded: Bool
    ) throws {
        if registrationAfterSuccess, succeeded {
            _ = try transition(attempt, to: .registrationPending)
        } else {
            try resolve(attempt)
        }
        internallyReconciledAttemptID = attempt.record.attemptID
    }

    func resolve(_ attempt: SecureFilesystemServiceLifecycleAttempt) throws {
        _ = try exactRecordUnlocked(for: attempt)
        if let recordURL {
            do {
                try OwnerOnlyAtomicFile.removeIfExists(at: recordURL)
            } catch {
                integrityFailure = true
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
        } else {
            inMemoryRecord = nil
        }
    }

    private func exactRecordUnlocked(
        for attempt: SecureFilesystemServiceLifecycleAttempt
    ) throws -> SecureFilesystemServiceLifecycleRecord {
        do {
            try attempt.lease.validateLinkedIdentity()
        } catch {
            integrityFailure = true
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        guard let existing = try validatedRecordUnlocked() else {
            integrityFailure = true
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        guard existing.operationID == attempt.record.operationID,
              existing.attemptID == attempt.record.attemptID else {
            integrityFailure = true
            throw SecureFilesystemServiceLifecycleError.superseded
        }
        guard existing.leaseDevice == attempt.lease.device,
              existing.leaseInode == attempt.lease.inode else {
            integrityFailure = true
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        return existing
    }

    private func replacing(
        _ record: SecureFilesystemServiceLifecycleRecord,
        attemptID: String? = nil,
        phase: SecureFilesystemServiceLifecycleRecordPhase? = nil,
        attemptNumber: Int? = nil,
        lease: SecureFilesystemServiceLifecycleLease
    ) -> SecureFilesystemServiceLifecycleRecord {
        SecureFilesystemServiceLifecycleRecord(
            schemaVersion: 2,
            operationID: record.operationID,
            attemptID: attemptID ?? record.attemptID,
            intent: record.intent,
            phase: phase ?? record.phase,
            attemptNumber: attemptNumber ?? record.normalizedAttemptNumber,
            leaseDevice: lease.device,
            leaseInode: lease.inode,
            createdAtMilliseconds: record.createdAtMilliseconds,
            updatedAtMilliseconds: max(
                record.createdAtMilliseconds,
                Self.nowMilliseconds()
            )
        )
    }

    private func acquireLease() throws -> SecureFilesystemServiceLifecycleLease {
        guard let recordURL else { return try memoryLeaseCoordinator.acquire() }
        let lockURL = recordURL.appendingPathExtension("lock")
        var created = false
        var descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = lockURL.path.withCString {
                Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        }
        guard descriptor >= 0 else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        var mustClose = true
        defer { if mustClose { _ = Darwin.close(descriptor) } }

        if created {
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
            do {
                try OwnerOnlyAtomicFile.synchronizeDirectory(
                    lockURL.deletingLastPathComponent()
                )
            } catch {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR) else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired
            }
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        mustClose = false
        let lease = SecureFilesystemServiceLifecycleLease(
            descriptor: descriptor,
            information: information,
            lockURL: lockURL
        )
        do {
            try lease.validateLinkedIdentity()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    private func validateRecordedLeaseIdentity(
        _ record: SecureFilesystemServiceLifecycleRecord,
        allowingLegacyRecord: Bool = false
    ) throws {
        guard let recordURL else { return }
        if allowingLegacyRecord,
           record.schemaVersion == 1,
           record.leaseDevice == nil,
           record.leaseInode == nil {
            return
        }
        guard let expectedDevice = record.leaseDevice,
              let expectedInode = record.leaseInode else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        let lockURL = recordURL.appendingPathExtension("lock")
        var information = stat()
        guard lockURL.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR),
              UInt64(information.st_dev) == expectedDevice,
              UInt64(information.st_ino) == expectedInode else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
    }

    private func validatedRecordUnlocked() throws
        -> SecureFilesystemServiceLifecycleRecord?
    {
        guard let record = try readRecordUnlocked() else { return nil }
        guard record.projectedState != nil else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        return record
    }

    private func readRecordUnlocked() throws -> SecureFilesystemServiceLifecycleRecord? {
        guard let recordURL else { return inMemoryRecord }
        var information = stat()
        let inspection = recordURL.path.withCString { Darwin.lstat($0, &information) }
        if inspection != 0 {
            guard errno == ENOENT else {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
            return nil
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
                == (S_IRUSR | S_IWUSR) else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        do {
            let data = try OwnerOnlyAtomicFile.read(
                from: recordURL,
                maximumBytes: Self.maximumRecordBytes
            )
            return try JSONDecoder().decode(
                SecureFilesystemServiceLifecycleRecord.self,
                from: data
            )
        } catch {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
    }

    private func persistUnlocked(_ record: SecureFilesystemServiceLifecycleRecord) throws {
        guard record.projectedState != nil else {
            throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
        }
        if let recordURL {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(record)
                guard data.count <= Self.maximumRecordBytes else {
                    throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
                }
                try OwnerOnlyAtomicFile.write(data, to: recordURL)
            } catch let error as SecureFilesystemServiceLifecycleError {
                throw error
            } catch {
                throw SecureFilesystemServiceLifecycleError.lifecycleStateInvalid
            }
        } else {
            inMemoryRecord = record
        }
    }

    private static func nowMilliseconds() -> Int64 {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int64.max) else { return 0 }
        return Int64(milliseconds.rounded(.down))
    }
}

protocol SecureFilesystemServiceTimeoutScheduling: Sendable {
    func schedule(
        after timeoutSeconds: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void
}

struct SecureFilesystemServiceTimeoutScheduler:
    SecureFilesystemServiceTimeoutScheduling {
    func schedule(
        after timeoutSeconds: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let boundedSeconds = max(0.001, min(timeoutSeconds, 300))
        let nanoseconds = UInt64(boundedSeconds * 1_000_000_000)
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return { timeoutTask.cancel() }
    }
}

private final class SecureFilesystemServiceLifecycleCompletion<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var cancelTimeout: (@Sendable () -> Void)?
    private var claimed = false

    func install(continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>?
        lock.lock()
        if let terminalResult {
            result = terminalResult
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result {
            continuation.resume(with: result)
        }
    }

    func installTimeoutCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let shouldCancelImmediately: Bool
        lock.lock()
        if terminalResult == nil, !claimed {
            cancelTimeout = cancellation
            shouldCancelImmediately = false
        } else {
            shouldCancelImmediately = true
        }
        lock.unlock()
        if shouldCancelImmediately {
            cancellation()
        }
    }

    func claim() -> Bool {
        let timeoutCancellation: (@Sendable () -> Void)?
        lock.lock()
        guard terminalResult == nil, !claimed else {
            lock.unlock()
            return false
        }
        claimed = true
        timeoutCancellation = cancelTimeout
        cancelTimeout = nil
        lock.unlock()
        timeoutCancellation?()
        return true
    }

    func completeClaim(with result: Result<Value, Error>) {
        let continuationToResume: CheckedContinuation<Value, Error>?
        let timeoutCancellation: (@Sendable () -> Void)?
        lock.lock()
        guard claimed, terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuationToResume = continuation
        continuation = nil
        timeoutCancellation = cancelTimeout
        cancelTimeout = nil
        lock.unlock()

        timeoutCancellation?()
        continuationToResume?.resume(with: result)
    }
}

protocol SecureFilesystemServiceRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func unregister(completionHandler: @Sendable @escaping (Error?) -> Void)
}

extension SMAppService: SecureFilesystemServiceRegistering {}

/// ServiceManagement's registration API is synchronous. The box is sent only
/// to one bounded detached task at a time while the cross-process lease is held.
private final class SecureFilesystemServiceRegistrationBox: @unchecked Sendable {
    let service: any SecureFilesystemServiceRegistering

    init(_ service: any SecureFilesystemServiceRegistering) {
        self.service = service
    }
}

enum SecureFilesystemServicePackageObservation: Error, Sendable, Equatable {
    case present
    case missing
    case invalid
}

protocol SecureFilesystemServicePackageInspecting: Sendable {
    func inspect() -> SecureFilesystemServicePackageObservation
}

struct MissingSecureFilesystemServicePackageInspector:
    SecureFilesystemServicePackageInspecting {
    func inspect() -> SecureFilesystemServicePackageObservation { .missing }
}

struct SecureFilesystemServiceBundleInspector:
    SecureFilesystemServicePackageInspecting {
    private static let maximumPropertyListBytes: off_t = 64 * 1_024
    private let applicationBundlePath: String

    init(applicationBundle: URL) {
        applicationBundlePath = applicationBundle.path
    }

    func inspect() -> SecureFilesystemServicePackageObservation {
        guard applicationBundlePath.hasPrefix("/") else { return .invalid }
        switch Self.openDirectory(atAbsolutePath: applicationBundlePath) {
        case .failure(let observation):
            return observation
        case .success(let applicationDescriptor):
            defer { Darwin.close(applicationDescriptor) }
            return inspectPackage(applicationDescriptor: applicationDescriptor)
        }
    }

    private func inspectPackage(
        applicationDescriptor: Int32
    ) -> SecureFilesystemServicePackageObservation {
        let daemonDirectory: Int32
        switch Self.openDirectory(
            relativeComponents: ["Contents", "MacOS"],
            from: applicationDescriptor
        ) {
        case .failure(let observation): return observation
        case .success(let descriptor): daemonDirectory = descriptor
        }
        defer { Darwin.close(daemonDirectory) }

        let launchDaemonDirectory: Int32
        switch Self.openDirectory(
            relativeComponents: ["Contents", "Library", "LaunchDaemons"],
            from: applicationDescriptor
        ) {
        case .failure(let observation): return observation
        case .success(let descriptor): launchDaemonDirectory = descriptor
        }
        defer { Darwin.close(launchDaemonDirectory) }

        let daemonDescriptor = Self.openRegularFile(
            ForgeFilesystemProtocolConstants.daemonExecutableName,
            from: daemonDirectory
        )
        guard daemonDescriptor >= 0 else { return Self.failureObservation() }
        defer { Darwin.close(daemonDescriptor) }

        var daemonInformation = stat()
        guard Darwin.fstat(daemonDescriptor, &daemonInformation) == 0,
              daemonInformation.st_mode & S_IFMT == S_IFREG,
              daemonInformation.st_nlink == 1,
              daemonInformation.st_size > 0,
              daemonInformation.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            return .invalid
        }

        let propertyListDescriptor = Self.openRegularFile(
            ForgeFilesystemProtocolConstants.daemonPlistName,
            from: launchDaemonDirectory
        )
        guard propertyListDescriptor >= 0 else { return Self.failureObservation() }
        defer { Darwin.close(propertyListDescriptor) }

        var propertyListInformation = stat()
        guard Darwin.fstat(propertyListDescriptor, &propertyListInformation) == 0,
              propertyListInformation.st_mode & S_IFMT == S_IFREG,
              propertyListInformation.st_nlink == 1,
              propertyListInformation.st_size > 0,
              propertyListInformation.st_size <= Self.maximumPropertyListBytes,
              let data = Self.readExactFile(
                  descriptor: propertyListDescriptor,
                  information: propertyListInformation
              ),
              Self.isExactServicePropertyList(data) else {
            return .invalid
        }
        return .present
    }

    private static func openDirectory(
        atAbsolutePath path: String
    ) -> Result<Int32, SecureFilesystemServicePackageObservation> {
        let rootDescriptor = Darwin.open(
            "/",
            O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard rootDescriptor >= 0 else { return .failure(.invalid) }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            Darwin.close(rootDescriptor)
            return .failure(.invalid)
        }
        return openDirectory(
            relativeComponents: components,
            fromOwnedDescriptor: rootDescriptor
        )
    }

    private static func openDirectory(
        relativeComponents components: [String],
        from descriptor: Int32
    ) -> Result<Int32, SecureFilesystemServicePackageObservation> {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return .failure(.invalid) }
        return openDirectory(
            relativeComponents: components,
            fromOwnedDescriptor: duplicate
        )
    }

    private static func openDirectory(
        relativeComponents components: [String],
        fromOwnedDescriptor descriptor: Int32
    ) -> Result<Int32, SecureFilesystemServicePackageObservation> {
        var currentDescriptor = descriptor
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                Darwin.close(currentDescriptor)
                return .failure(.invalid)
            }
            let nextDescriptor = component.withCString { pointer in
                Darwin.openat(
                    currentDescriptor,
                    pointer,
                    O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                )
            }
            guard nextDescriptor >= 0 else {
                let observation = failureObservation()
                Darwin.close(currentDescriptor)
                return .failure(observation)
            }
            var information = stat()
            guard Darwin.fstat(nextDescriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(nextDescriptor)
                Darwin.close(currentDescriptor)
                return .failure(.invalid)
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return .success(currentDescriptor)
    }

    private static func openRegularFile(_ name: String, from descriptor: Int32) -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            errno = EINVAL
            return -1
        }
        return name.withCString { pointer in
            Darwin.openat(
                descriptor,
                pointer,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
            )
        }
    }

    private static func readExactFile(
        descriptor: Int32,
        information: stat
    ) -> Data? {
        let expectedSize = Int(information.st_size)
        var data = Data(count: expectedSize)
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            var offset = 0
            while offset < expectedSize {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedSize - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard bytesRead == expectedSize else { return nil }

        var extraByte: UInt8 = 0
        let trailingRead = withUnsafeMutablePointer(to: &extraByte) {
            Darwin.read(descriptor, $0, 1)
        }
        guard trailingRead == 0 else { return nil }

        var finalInformation = stat()
        guard Darwin.fstat(descriptor, &finalInformation) == 0,
              finalInformation.st_dev == information.st_dev,
              finalInformation.st_ino == information.st_ino,
              finalInformation.st_size == information.st_size,
              finalInformation.st_mtimespec.tv_sec == information.st_mtimespec.tv_sec,
              finalInformation.st_mtimespec.tv_nsec == information.st_mtimespec.tv_nsec,
              finalInformation.st_ctimespec.tv_sec == information.st_ctimespec.tv_sec,
              finalInformation.st_ctimespec.tv_nsec == information.st_ctimespec.tv_nsec else {
            return nil
        }
        return data
    }

    private static func isExactServicePropertyList(_ data: Data) -> Bool {
        guard let value = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = value as? [String: Any],
        Set(dictionary.keys) == Set([
            "BundleProgram",
            "Label",
            "MachServices",
            "Umask",
            "UserName",
        ]),
        dictionary["Label"] as? String == ForgeFilesystemProtocolConstants.serviceName,
        dictionary["BundleProgram"] as? String
            == "Contents/MacOS/"
                + ForgeFilesystemProtocolConstants.daemonExecutableName,
        dictionary["UserName"] as? String == "root",
        dictionary["Umask"] as? Int == 0o077,
        let machServices = dictionary["MachServices"] as? [String: Any],
        machServices.count == 1,
        machServices[ForgeFilesystemProtocolConstants.serviceName] as? Bool == true else {
            return false
        }
        return true
    }

    private static func failureObservation() -> SecureFilesystemServicePackageObservation {
        errno == ENOENT ? .missing : .invalid
    }
}

@MainActor
public final class SecureFilesystemServiceController {
    private var lifecycleGeneration: UInt64 = 0
    private var activeLifecycleOperationID: UUID?
    private let registeredService: any SecureFilesystemServiceRegistering
    private let registrationBox: SecureFilesystemServiceRegistrationBox
    private let packageInspector: any SecureFilesystemServicePackageInspecting
    private let serviceUnregisterTimeoutSeconds: TimeInterval
    private let timeoutScheduler: any SecureFilesystemServiceTimeoutScheduling
    private let operationalTransport: any SecureFilesystemServiceTransport
    private let lifecyclePhaseObserver:
        (@Sendable (SecureFilesystemServiceLifecyclePhase) -> Void)?
    private var lifecycleStateObserver:
        (@MainActor @Sendable (SecureFilesystemServiceLifecycleObservation) -> Void)?
    private let beforeUncertaintyPersistence: (@Sendable () async -> Void)?
    private var packageObservation: SecureFilesystemServicePackageObservation?
    private var packageInspectionTask:
        Task<SecureFilesystemServicePackageObservation, Never>?
    private var packageInspectionGeneration: UInt64 = 0
    private var lifecycleFenceStore = SecureFilesystemServiceLifecycleFenceStore()

    public init() {
        let service = SMAppService.daemon(
            plistName: ForgeFilesystemProtocolConstants.daemonPlistName
        )
        registeredService = service
        registrationBox = SecureFilesystemServiceRegistrationBox(service)
        packageInspector = SecureFilesystemServiceBundleInspector(
            applicationBundle: Bundle.main.bundleURL
        )
        serviceUnregisterTimeoutSeconds = 30
        timeoutScheduler = SecureFilesystemServiceTimeoutScheduler()
        operationalTransport = XPCSecureFilesystemServiceTransport()
        lifecyclePhaseObserver = nil
        lifecycleStateObserver = nil
        beforeUncertaintyPersistence = nil
        lifecycleFenceStore = SecureFilesystemServiceLifecycleFenceStore(
            recordURL: Self.lifecycleFenceURL(paths: AppPaths())
        )
    }

    init(
        service: any SecureFilesystemServiceRegistering,
        packageInspector: any SecureFilesystemServicePackageInspecting =
            MissingSecureFilesystemServicePackageInspector(),
        unregisterTimeoutSeconds: TimeInterval = 30,
        timeoutScheduler: any SecureFilesystemServiceTimeoutScheduling =
            SecureFilesystemServiceTimeoutScheduler(),
        operationalTransport: any SecureFilesystemServiceTransport =
            XPCSecureFilesystemServiceTransport(),
        lifecycleFenceURL: URL? = nil,
        lifecyclePhaseObserver:
            (@Sendable (SecureFilesystemServiceLifecyclePhase) -> Void)? = nil,
        beforeUncertaintyPersistence: (@Sendable () async -> Void)? = nil
    ) {
        registeredService = service
        registrationBox = SecureFilesystemServiceRegistrationBox(service)
        self.packageInspector = packageInspector
        serviceUnregisterTimeoutSeconds = unregisterTimeoutSeconds
        self.timeoutScheduler = timeoutScheduler
        self.operationalTransport = operationalTransport
        self.lifecyclePhaseObserver = lifecyclePhaseObserver
        lifecycleStateObserver = nil
        self.beforeUncertaintyPersistence = beforeUncertaintyPersistence
        lifecycleFenceStore = SecureFilesystemServiceLifecycleFenceStore(
            recordURL: lifecycleFenceURL
        )
    }

    /// Binds the controller to the exact application home before any lifecycle
    /// action. Reading the returned state is observational; it never reconciles
    /// filesystem recovery debt or invokes ServiceManagement.
    public func configureLifecycleFence(
        paths: AppPaths
    ) async -> SecureFilesystemServiceLifecycleState {
        guard activeLifecycleOperationID == nil else {
            return SecureFilesystemServiceLifecycleState(phase: .stateInvalid)
        }
        lifecycleFenceStore = SecureFilesystemServiceLifecycleFenceStore(
            recordURL: Self.lifecycleFenceURL(paths: paths)
        )
        return await lifecycleFenceStore.state()
    }

    public func lifecycleState() async -> SecureFilesystemServiceLifecycleState {
        await lifecycleFenceStore.state()
    }

    public func setLifecycleStateObserver(
        _ observer:
            (@MainActor @Sendable (SecureFilesystemServiceLifecycleObservation) -> Void)?
    ) {
        lifecycleStateObserver = observer
    }

    public func status() -> SecureFilesystemServiceStatus {
        Self.status(of: registeredService)
    }

    public func presentedStatus() async -> SecureFilesystemServiceStatus {
        guard status() == .notFound else { return status() }
        let observation: SecureFilesystemServicePackageObservation
        if let packageObservation {
            observation = packageObservation
        } else {
            let inspectionTask: Task<SecureFilesystemServicePackageObservation, Never>
            let inspectionGeneration: UInt64
            if let packageInspectionTask {
                inspectionTask = packageInspectionTask
                inspectionGeneration = packageInspectionGeneration
            } else {
                let inspector = packageInspector
                inspectionTask = Task.detached(priority: .utility) {
                    inspector.inspect()
                }
                packageInspectionGeneration &+= 1
                inspectionGeneration = packageInspectionGeneration
                packageInspectionTask = inspectionTask
            }
            observation = await inspectionTask.value
            if packageInspectionGeneration == inspectionGeneration {
                if observation == .present {
                    packageObservation = observation
                }
                packageInspectionTask = nil
            }
        }
        return Self.presentedStatus(
            reportedStatus: status(),
            packageObservation: observation
        )
    }

    /// Reports the registration and authenticated runtime states separately,
    /// while reconciling only identity-verifiable fixed-slot debt. No paths or
    /// receipt contents leave the lifecycle boundary.
    public func operationalHealth(
        paths: AppPaths,
        reconcile: Bool = false
    ) async -> SecureFilesystemOperationalHealth {
        let registrationStatus = await presentedStatus()
        let transport = operationalTransport
        return await Task.detached(priority: .utility) {
            SecureFilesystemOperationalLifecycle.evaluate(
                registrationStatus: registrationStatus,
                paths: paths,
                transport: transport,
                reconcile: reconcile
            )
        }.value
    }

    @discardableResult
    public func register() async throws -> SecureFilesystemServiceStatus {
        try await register(observationContext: nil)
    }

    @discardableResult
    public func register(
        lifecycleObservationContext context:
            SecureFilesystemServiceLifecycleObservationContext
    ) async throws -> SecureFilesystemServiceStatus {
        try await register(observationContext: context)
    }

    private func register(
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let operationID = try beginLifecycleOperation()
        defer { finishLifecycleOperation(operationID) }
        let attempt = try await lifecycleFenceStore.begin(
            intent: .enable,
            phase: .registering
        )
        publishLifecycleState(
            attempt,
            phase: .registering,
            observationContext: observationContext
        )
        return try await waitForServiceRegister(
            attempt: attempt,
            observationContext: observationContext
        )
    }

    /// Disables the service only after ServiceManagement reports that its
    /// asynchronous unregister operation completed. A timeout or task
    /// cancellation leaves a durable fence instead of treating cancellation as
    /// cancellation of the operating-system request.
    @discardableResult
    public func unregister() async throws -> SecureFilesystemServiceStatus {
        try await unregister(observationContext: nil)
    }

    @discardableResult
    public func unregister(
        lifecycleObservationContext context:
            SecureFilesystemServiceLifecycleObservationContext
    ) async throws -> SecureFilesystemServiceStatus {
        try await unregister(observationContext: context)
    }

    private func unregister(
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let operationID = try beginLifecycleOperation()
        defer { finishLifecycleOperation(operationID) }
        let attempt = try await lifecycleFenceStore.begin(
            intent: .disable,
            phase: .unregistering
        )
        publishLifecycleState(
            attempt,
            phase: .unregistering,
            observationContext: observationContext
        )
        _ = try await waitForServiceUnregister(
            attempt: attempt,
            registrationAfterSuccess: false,
            observationContext: observationContext
        )
        return status()
    }

    /// Replaces a previously registered daemon after an app or helper update.
    /// ServiceManagement documents that an updated daemon executable should be
    /// unregistered before re-registration, and its synchronous unregister does
    /// not wait for the old process to be reaped. The completion-handler form is
    /// therefore the only safe transition point for registering the replacement.
    @discardableResult
    public func reinstall() async throws -> SecureFilesystemServiceStatus {
        try await reinstall(observationContext: nil)
    }

    @discardableResult
    public func reinstall(
        lifecycleObservationContext context:
            SecureFilesystemServiceLifecycleObservationContext
    ) async throws -> SecureFilesystemServiceStatus {
        try await reinstall(observationContext: context)
    }

    private func reinstall(
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let operationID = try beginLifecycleOperation()
        defer { finishLifecycleOperation(operationID) }
        var attempt = try await lifecycleFenceStore.begin(
            intent: .update,
            phase: .unregistering
        )
        switch registeredService.status {
        case .enabled, .requiresApproval:
            publishLifecycleState(
                attempt,
                phase: .unregistering,
                observationContext: observationContext
            )
            attempt = try await waitForServiceUnregister(
                attempt: attempt,
                registrationAfterSuccess: true,
                observationContext: observationContext
            ) ?? attempt
        case .notRegistered, .notFound:
            attempt = try await lifecycleFenceStore.transition(
                attempt,
                to: .registering
            )
            publishLifecycleState(
                attempt,
                phase: .registering,
                observationContext: observationContext
            )
        @unknown default:
            attempt = try await lifecycleFenceStore.transition(
                attempt,
                to: .registering
            )
            publishLifecycleState(
                attempt,
                phase: .registering,
                observationContext: observationContext
            )
        }
        if Task.isCancelled {
            // The reap may already have committed registration_pending, or a
            // no-longer-registered service may already be in registering.
            // Cancellation must preserve that durable Update intent for the
            // next recovery owner instead of silently abandoning replacement.
            attempt.lease.release()
            throw CancellationError()
        }
        guard activeLifecycleOperationID == operationID else {
            attempt.lease.release()
            throw SecureFilesystemServiceLifecycleError.superseded
        }
        if attempt.record.phase != .registering {
            attempt = try await lifecycleFenceStore.transition(
                attempt,
                to: .registering
            )
            publishLifecycleState(
                attempt,
                phase: .registering,
                observationContext: observationContext
            )
        }
        return try await waitForServiceRegister(
            attempt: attempt,
            observationContext: observationContext
        )
    }

    /// Recovers one durable lifecycle phase only after obtaining the same stable
    /// cross-process lease. Uncertain Update recovery remains unregister-only;
    /// only a durable registration-pending/registering phase can authorize a
    /// registration retry.
    @discardableResult
    public func recoverInterruptedUnregister() async throws
        -> SecureFilesystemServiceStatus
    {
        try await recoverInterruptedUnregister(observationContext: nil)
    }

    @discardableResult
    private func recoverInterruptedUnregister(
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let operationID = try beginLifecycleOperation()
        defer { finishLifecycleOperation(operationID) }
        guard let recovery = try await lifecycleFenceStore.prepareRecovery() else {
            return status()
        }
        switch recovery.action {
        case .unregister:
            publishLifecycleState(
                recovery.attempt,
                phase: .unregistering,
                observationContext: observationContext
            )
            let registrationPending = try await waitForServiceUnregister(
                attempt: recovery.attempt,
                registrationAfterSuccess:
                    recovery.attempt.record.intent
                        == SecureFilesystemServiceLifecycleIntent.update.rawValue,
                observationContext: observationContext
            )
            // Update recovery intentionally advances one durable phase per
            // call. A second recovery owner may register only from the
            // registration_pending record created after the successful reap.
            registrationPending?.lease.release()
            return status()
        case .register:
            publishLifecycleState(
                recovery.attempt,
                phase: .registering,
                observationContext: observationContext
            )
            switch registeredService.status {
            case .enabled, .requiresApproval:
                do {
                    try await lifecycleFenceStore.resolve(recovery.attempt)
                } catch {
                    recovery.attempt.lease.release()
                    throw error
                }
                recovery.attempt.lease.release()
                publishLifecycleObservation(
                    .settled,
                    observationContext: observationContext
                )
                return status()
            case .notRegistered, .notFound:
                return try await waitForServiceRegister(
                    attempt: recovery.attempt,
                    observationContext: observationContext
                )
            @unknown default:
                return try await waitForServiceRegister(
                    attempt: recovery.attempt,
                    observationContext: observationContext
                )
            }
        }
    }

    /// Drives at most the two durable phases needed to recover an interrupted
    /// Update (reap, then register). Each phase retains the exact one-side-effect
    /// recovery semantics above, and any timeout/error stops the bounded loop.
    @discardableResult
    public func recoverInterruptedLifecycle(
        maximumPhases: Int = 2
    ) async throws -> SecureFilesystemServiceStatus {
        try await recoverInterruptedLifecycle(
            maximumPhases: maximumPhases,
            observationContext: nil
        )
    }

    @discardableResult
    public func recoverInterruptedLifecycle(
        maximumPhases: Int = 2,
        lifecycleObservationContext context:
            SecureFilesystemServiceLifecycleObservationContext
    ) async throws -> SecureFilesystemServiceStatus {
        try await recoverInterruptedLifecycle(
            maximumPhases: maximumPhases,
            observationContext: context
        )
    }

    private func recoverInterruptedLifecycle(
        maximumPhases: Int,
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let boundedPhases = max(1, min(maximumPhases, 2))
        var recoveredStatus = status()
        for _ in 0..<boundedPhases {
            let durableState = await lifecycleState()
            guard durableState.canRetryResolution else { return recoveredStatus }
            recoveredStatus = try await recoverInterruptedUnregister(
                observationContext: observationContext
            )
        }
        return recoveredStatus
    }

    private func waitForServiceUnregister(
        attempt: SecureFilesystemServiceLifecycleAttempt,
        registrationAfterSuccess: Bool,
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceLifecycleAttempt? {
        let completion = SecureFilesystemServiceLifecycleCompletion<
            SecureFilesystemServiceLifecycleAttempt?
        >()
        let store = lifecycleFenceStore
        let phaseObserver = lifecyclePhaseObserver
        let stateObserver = lifecycleStateObserver
        let uncertaintyHook = beforeUncertaintyPersistence
        try await store.requireCurrent(attempt)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<
                    SecureFilesystemServiceLifecycleAttempt?, Error
                >) in
                completion.install(continuation: continuation)
                registeredService.unregister { error in
                    Task { @MainActor in
                        guard completion.claim() else {
                            let observedState:
                                SecureFilesystemServiceLifecycleState?
                            do {
                                try await store.reconcileLateUnregisterCallback(
                                    attempt,
                                    registrationAfterSuccess: registrationAfterSuccess,
                                    succeeded: error == nil
                                )
                                if registrationAfterSuccess, error == nil {
                                    phaseObserver?(.registrationPending)
                                }
                                observedState = observationContext == nil
                                    ? nil
                                    : await store.state()
                            } catch {
                                // A missing, replaced, or superseded exact record
                                // remains fail-closed in the store's invalid latch.
                                observedState = observationContext == nil
                                    ? nil
                                    : await store.state()
                            }
                            attempt.lease.release()
                            if let observationContext, let observedState {
                                stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                    context: observationContext,
                                    state: observedState
                                ))
                            }
                            return
                        }
                        do {
                            if let error {
                                try await store.resolve(attempt)
                                attempt.lease.release()
                                if let observationContext {
                                    stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                        context: observationContext,
                                        state: .settled
                                    ))
                                }
                                completion.completeClaim(with: .failure(error))
                            } else if registrationAfterSuccess {
                                let next = try await store.transition(
                                    attempt,
                                    to: .registrationPending
                                )
                                phaseObserver?(.registrationPending)
                                if let observationContext,
                                   let state = next.record.projectedState {
                                    stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                        context: observationContext,
                                        state: state
                                    ))
                                }
                                completion.completeClaim(with: .success(next))
                            } else {
                                try await store.resolve(attempt)
                                attempt.lease.release()
                                if let observationContext {
                                    stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                        context: observationContext,
                                        state: .settled
                                    ))
                                }
                                completion.completeClaim(with: .success(nil))
                            }
                        } catch {
                            let observedState = observationContext == nil
                                ? nil
                                : await store.state()
                            attempt.lease.release()
                            if let observationContext, let observedState {
                                stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                    context: observationContext,
                                    state: observedState
                                ))
                            }
                            completion.completeClaim(with: .failure(error))
                        }
                    }
                }
                let cancelTimeout = timeoutScheduler.schedule(
                    after: serviceUnregisterTimeoutSeconds
                ) {
                    guard completion.claim() else { return }
                    Task { @MainActor in
                        await uncertaintyHook?()
                        do {
                            try await store.markUncertain(attempt)
                            if let observationContext {
                                let state = await store.state()
                                stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                    context: observationContext,
                                    state: state
                                ))
                            }
                            completion.completeClaim(with: .failure(
                                SecureFilesystemServiceLifecycleError.unregisterTimedOut
                            ))
                        } catch {
                            if let observationContext {
                                let state = await store.state()
                                stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                    context: observationContext,
                                    state: state
                                ))
                            }
                            attempt.lease.release()
                            completion.completeClaim(with: .failure(error))
                        }
                    }
                }
                completion.installTimeoutCancellation(cancelTimeout)
            }
        }, onCancel: {
            guard completion.claim() else { return }
            Task { @MainActor in
                await uncertaintyHook?()
                do {
                    try await store.markUncertain(attempt)
                    if let observationContext {
                        let state = await store.state()
                        stateObserver?(SecureFilesystemServiceLifecycleObservation(
                            context: observationContext,
                            state: state
                        ))
                    }
                    completion.completeClaim(with: .failure(CancellationError()))
                } catch {
                    if let observationContext {
                        let state = await store.state()
                        stateObserver?(SecureFilesystemServiceLifecycleObservation(
                            context: observationContext,
                            state: state
                        ))
                    }
                    attempt.lease.release()
                    completion.completeClaim(with: .failure(error))
                }
            }
        })
    }

    /// Runs synchronous ServiceManagement registration outside the main actor.
    /// Timeout/cancellation returns to the caller while the single bounded worker
    /// and its lease remain alive until the system call's exact result is reconciled.
    private func waitForServiceRegister(
        attempt: SecureFilesystemServiceLifecycleAttempt,
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) async throws -> SecureFilesystemServiceStatus {
        let completion = SecureFilesystemServiceLifecycleCompletion<
            SecureFilesystemServiceStatus
        >()
        let store = lifecycleFenceStore
        let box = registrationBox
        let stateObserver = lifecycleStateObserver
        try await store.requireCurrent(attempt)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SecureFilesystemServiceStatus, Error>) in
                completion.install(continuation: continuation)
                Task.detached(priority: .userInitiated) {
                    let registrationResult: Result<SecureFilesystemServiceStatus, Error>
                    do {
                        try box.service.register()
                        registrationResult = .success(Self.status(of: box.service))
                    } catch {
                        registrationResult = .failure(error)
                    }

                    guard completion.claim() else {
                        do {
                            try await store.resolve(attempt)
                        } catch {
                            // Preserve the fail-closed invalid latch on mismatch.
                        }
                        if let observationContext {
                            let state = await store.state()
                            attempt.lease.release()
                            await stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                context: observationContext,
                                state: state
                            ))
                        } else {
                            attempt.lease.release()
                        }
                        return
                    }
                    do {
                        try await store.resolve(attempt)
                        attempt.lease.release()
                        if let observationContext {
                            await stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                context: observationContext,
                                state: .settled
                            ))
                        }
                        completion.completeClaim(with: registrationResult)
                    } catch {
                        let observedState = observationContext == nil
                            ? nil
                            : await store.state()
                        attempt.lease.release()
                        if let observationContext, let observedState {
                            await stateObserver?(SecureFilesystemServiceLifecycleObservation(
                                context: observationContext,
                                state: observedState
                            ))
                        }
                        completion.completeClaim(with: .failure(error))
                    }
                }
                let cancelTimeout = timeoutScheduler.schedule(
                    after: serviceUnregisterTimeoutSeconds
                ) {
                    guard completion.claim() else { return }
                    completion.completeClaim(with: .failure(
                        SecureFilesystemServiceLifecycleError.registerTimedOut
                    ))
                }
                completion.installTimeoutCancellation(cancelTimeout)
            }
        }, onCancel: {
            guard completion.claim() else { return }
            completion.completeClaim(with: .failure(CancellationError()))
        })
    }

    private func publishLifecycleState(
        _ attempt: SecureFilesystemServiceLifecycleAttempt,
        phase: SecureFilesystemServiceLifecyclePhase,
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) {
        lifecyclePhaseObserver?(phase)
        guard let observationContext,
              let state = attempt.record.projectedState else { return }
        lifecycleStateObserver?(SecureFilesystemServiceLifecycleObservation(
            context: observationContext,
            state: state
        ))
    }

    private func publishLifecycleObservation(
        _ state: SecureFilesystemServiceLifecycleState,
        observationContext:
            SecureFilesystemServiceLifecycleObservationContext?
    ) {
        guard let observationContext else { return }
        lifecycleStateObserver?(SecureFilesystemServiceLifecycleObservation(
            context: observationContext,
            state: state
        ))
    }

    private func beginLifecycleOperation() throws -> UUID {
        guard activeLifecycleOperationID == nil,
              lifecycleGeneration < UInt64.max else {
            throw SecureFilesystemServiceLifecycleError.lifecycleResolutionRequired
        }
        lifecycleGeneration += 1
        let operationID = UUID()
        activeLifecycleOperationID = operationID
        return operationID
    }

    private func finishLifecycleOperation(_ operationID: UUID) {
        guard activeLifecycleOperationID == operationID else { return }
        activeLifecycleOperationID = nil
    }

    private nonisolated static func lifecycleFenceURL(paths: AppPaths) -> URL {
        paths.home
            .appendingPathComponent(
                ".protected-filesystem-unregister-v1.json",
                isDirectory: false
            )
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    nonisolated static func registrationStatus() -> SecureFilesystemServiceStatus {
        status(of: SMAppService.daemon(
            plistName: ForgeFilesystemProtocolConstants.daemonPlistName
        ))
    }

    private nonisolated static func status(
        of service: any SecureFilesystemServiceRegistering
    ) -> SecureFilesystemServiceStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    nonisolated static func presentedStatus(
        reportedStatus: SecureFilesystemServiceStatus,
        packageObservation: SecureFilesystemServicePackageObservation
    ) -> SecureFilesystemServiceStatus {
        guard reportedStatus == .notFound, packageObservation == .present else {
            return reportedStatus
        }
        // Background Task Management also reports notFound when the package is
        // valid but has never been registered. This presentation-only mapping
        // does not affect the raw service or XPC authorization status.
        return .notRegistered
    }
}

protocol SecureFilesystemServiceTransport: Sendable {
    func serviceStatus() -> SecureFilesystemServiceStatus
    func operationalProbe(timeout: TimeInterval) -> SecureFilesystemServiceOperationalProbe
    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse
    func queryTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemTransactionStatus
    func resumeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse
    func acknowledgeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse
}

struct SecureFilesystemHandshakeStateMachine {
    enum Phase: Equatable {
        case awaitingIdentity
        case dispatchAuthorized
        case requestSubmitted
        case finished
    }

    enum ServiceInfoDisposition: Equatable {
        case prepareDispatch
        case finishWithoutDispatch
        case ignore
    }

    private(set) var phase: Phase = .awaitingIdentity
    private(set) var terminalResponse: ForgeFilesystemResponse?
    private let transactionID: String

    init(request: ForgeFilesystemMutationRequest) {
        self.init(transactionID: request.transactionID)
    }

    init(transactionID: String) {
        self.transactionID = transactionID
    }

    mutating func receiveServiceInfo<S: Sequence>(
        _ information: ForgeFilesystemServiceInfo,
        allowedCodeDirectoryHashes: S
    ) -> ServiceInfoDisposition where S.Element == String {
        guard phase == .awaitingIdentity else { return .ignore }
        guard information.matchesExpectedService(
            allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
        ) else {
            terminalResponse = ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "Secure filesystem service version or runtime identity does not match"
            )
            phase = .finished
            return .finishWithoutDispatch
        }
        phase = .dispatchAuthorized
        return .prepareDispatch
    }

    /// Transitions to submitted and synchronously invokes the supplied dispatch
    /// operation. The coordinator holds its lifecycle lock across this method,
    /// so timeout completion cannot interleave between the transition and send.
    mutating func dispatchIfAuthorized(_ dispatch: () -> Void) -> Bool {
        guard phase == .dispatchAuthorized else { return false }
        phase = .requestSubmitted
        dispatch()
        return true
    }

    @discardableResult
    mutating func completeReply(_ response: ForgeFilesystemResponse) -> Bool {
        guard phase == .requestSubmitted else { return false }
        terminalResponse = response
        phase = .finished
        return true
    }

    /// A lost connection or timeout before submission carries no recovery ID.
    /// Once submission begins, the original transaction ID is retained because
    /// the daemon may have durably recorded or committed the request.
    @discardableResult
    mutating func completeWithoutReply(code: String, message: String) -> Bool {
        guard phase != .finished else { return false }
        let recoveryTransactionID = phase == .requestSubmitted ? transactionID : nil
        terminalResponse = ForgeFilesystemResponse(
            ok: false,
            code: code,
            message: message,
            recoveryTransactionID: recoveryTransactionID
        )
        phase = .finished
        return true
    }
}

private final class SecureFilesystemHandshakeCoordinator: @unchecked Sendable {
    // The XPC reply is asynchronous, but use a recursive lock so an unusual
    // synchronous error callback cannot deadlock the lifecycle coordinator.
    private let lock = NSRecursiveLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var machine: SecureFilesystemHandshakeStateMachine

    init(request: ForgeFilesystemMutationRequest) {
        machine = SecureFilesystemHandshakeStateMachine(request: request)
    }

    init(transactionID: String) {
        machine = SecureFilesystemHandshakeStateMachine(transactionID: transactionID)
    }

    func receiveServiceInfo(
        _ information: ForgeFilesystemServiceInfo,
        allowedCodeDirectoryHashes: [String]
    ) -> SecureFilesystemHandshakeStateMachine.ServiceInfoDisposition {
        lock.lock()
        let disposition = machine.receiveServiceInfo(
            information,
            allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
        )
        lock.unlock()
        if disposition == .finishWithoutDispatch { completionSignal.signal() }
        return disposition
    }

    func dispatchIfAuthorized(_ dispatch: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return machine.dispatchIfAuthorized(dispatch)
    }

    func completeReply(_ response: ForgeFilesystemResponse) {
        lock.lock()
        let didFinish = machine.completeReply(response)
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func completeWithoutReply(code: String, message: String) {
        lock.lock()
        let didFinish = machine.completeWithoutReply(code: code, message: message)
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        completionSignal.wait(timeout: .now() + timeout)
    }

    var terminalResponse: ForgeFilesystemResponse? {
        lock.lock()
        defer { lock.unlock() }
        return machine.terminalResponse
    }
}

private final class SecureFilesystemStatusHandshakeCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var machine: SecureFilesystemHandshakeStateMachine
    private var storedStatus: ForgeFilesystemTransactionStatus?

    init(transactionID: String) {
        machine = SecureFilesystemHandshakeStateMachine(transactionID: transactionID)
    }

    func receiveServiceInfo(
        _ information: ForgeFilesystemServiceInfo,
        allowedCodeDirectoryHashes: [String]
    ) -> SecureFilesystemHandshakeStateMachine.ServiceInfoDisposition {
        lock.lock()
        let disposition = machine.receiveServiceInfo(
            information,
            allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
        )
        if disposition == .finishWithoutDispatch,
           let response = machine.terminalResponse {
            storedStatus = Self.failureStatus(response)
        }
        lock.unlock()
        if disposition == .finishWithoutDispatch { completionSignal.signal() }
        return disposition
    }

    func dispatchIfAuthorized(_ dispatch: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return machine.dispatchIfAuthorized(dispatch)
    }

    func completeReply(_ status: ForgeFilesystemTransactionStatus) {
        lock.lock()
        let didFinish = machine.completeReply(ForgeFilesystemResponse(
            ok: status.disposition != .unavailable,
            code: status.code,
            message: status.message,
            committed: status.committed,
            durabilityConfirmed: status.durabilityConfirmed,
            recoveryTransactionID: status.recoveryRequired ? status.transactionID : nil,
            acknowledgementRequired: status.acknowledgementRequired
        ))
        if didFinish { storedStatus = status }
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func completeWithoutReply(code: String, message: String) {
        lock.lock()
        let didFinish = machine.completeWithoutReply(code: code, message: message)
        if didFinish, let response = machine.terminalResponse {
            storedStatus = Self.failureStatus(response)
        }
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        completionSignal.wait(timeout: .now() + timeout)
    }

    var terminalStatus: ForgeFilesystemTransactionStatus? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    private static func failureStatus(
        _ response: ForgeFilesystemResponse
    ) -> ForgeFilesystemTransactionStatus {
        if let transactionID = response.recoveryTransactionID {
            return ForgeFilesystemTransactionStatus(
                transactionID: transactionID,
                disposition: .recoveryRequired,
                code: response.code,
                message: response.message,
                terminal: false,
                committed: false,
                durabilityConfirmed: false,
                recoveryRequired: true,
                acknowledgementRequired: false
            )
        }
        return ForgeFilesystemTransactionStatus(
            transactionID: nil,
            disposition: .unavailable,
            code: response.code,
            message: response.message,
            terminal: false,
            committed: false,
            durabilityConfirmed: false,
            recoveryRequired: false,
            acknowledgementRequired: false
        )
    }
}

final class XPCSecureFilesystemServiceTransport: SecureFilesystemServiceTransport,
    @unchecked Sendable
{
    func serviceStatus() -> SecureFilesystemServiceStatus {
        let reportedStatus = SecureFilesystemServiceController.registrationStatus()
        return Self.transportStatus(
            reportedStatus: reportedStatus,
            securedInfoDictionary: ForgeFilesystemCodeIdentity.currentSecuredInfoDictionary()
        )
    }

    func operationalProbe(timeout: TimeInterval) -> SecureFilesystemServiceOperationalProbe {
        guard let configuration = authenticatedPeerConfiguration() else {
            return SecureFilesystemServiceOperationalProbe(
                operational: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "The packaged secure filesystem service identity is unavailable"
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemServiceXPC.self
        )
        connection.setCodeSigningRequirement(configuration.signingRequirement)
        let coordinator = SecureFilesystemHandshakeCoordinator(
            transactionID: UUID().uuidString.lowercased()
        )
        connection.interruptionHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was interrupted"
            )
        }
        connection.invalidationHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was invalidated"
            )
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let failure = Self.connectionFailure(error)
            coordinator.completeWithoutReply(code: failure.code, message: failure.message)
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return SecureFilesystemServiceOperationalProbe(
                operational: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            let disposition = coordinator.receiveServiceInfo(
                information,
                allowedCodeDirectoryHashes: configuration.allowedCodeDirectoryHashes
            )
            guard disposition == .prepareDispatch else { return }
            _ = coordinator.dispatchIfAuthorized {
                proxy.status { response in coordinator.completeReply(response) }
            }
        }
        let boundedTimeout = max(0.001, min(10, timeout))
        if coordinator.wait(timeout: boundedTimeout) == .timedOut {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service status probe timed out"
            )
        }
        let response = coordinator.terminalResponse
        connection.invalidate()
        guard let response, response.validationError() == nil else {
            return SecureFilesystemServiceOperationalProbe(
                operational: false,
                code: ForgeFilesystemErrorCode.protocolMismatch,
                message: "Secure filesystem service returned invalid status"
            )
        }
        return SecureFilesystemServiceOperationalProbe(
            operational: response.ok
                && response.code == "ok"
                && response.durabilityConfirmed,
            code: response.code,
            message: response.message
        )
    }

    static func transportStatus(
        reportedStatus: SecureFilesystemServiceStatus,
        securedInfoDictionary: [String: Any]?
    ) -> SecureFilesystemServiceStatus {
        guard reportedStatus == .notFound,
              let securedInfoDictionary,
              ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
                  inSecuredInfoDictionary: securedInfoDictionary
              ) != nil else {
            return reportedStatus
        }
        // A separately signed CLI cannot reliably observe the app-owned
        // SMAppService registration. Permit an authenticated XPC probe only
        // when the caller's sealed identity metadata contains a valid hash set.
        return .enabled
    }

    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        guard let securedInfo = ForgeFilesystemCodeIdentity.currentSecuredInfoDictionary(),
              let allowedCodeDirectoryHashes = ForgeFilesystemCodeIdentity
                  .daemonCodeDirectoryHashes(inSecuredInfoDictionary: securedInfo),
              let signingRequirement = ForgeFilesystemProtocolConstants
                  .requiredDaemonCodeSigningRequirement(
                      codeDirectoryHashes: allowedCodeDirectoryHashes
                  ) else {
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "The packaged secure filesystem service identity is unavailable"
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemServiceXPC.self
        )
        connection.setCodeSigningRequirement(signingRequirement)
        let coordinator = SecureFilesystemHandshakeCoordinator(request: request)
        connection.interruptionHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was interrupted"
            )
        }
        connection.invalidationHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was invalidated"
            )
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let description = error.localizedDescription.lowercased()
            let identityFailure = description.contains("code sign")
                || description.contains("requirement")
            coordinator.completeWithoutReply(
                code: identityFailure
                    ? ForgeFilesystemErrorCode.helperIdentityMismatch
                    : ForgeFilesystemErrorCode.helperUnavailable,
                message: identityFailure
                    ? "Secure filesystem service identity validation failed"
                    : "Secure filesystem service connection failed"
            )
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            let disposition = coordinator.receiveServiceInfo(
                information,
                allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
            )
            guard disposition == .prepareDispatch else { return }
            _ = coordinator.dispatchIfAuthorized {
                proxy.deleteLeaf(request, authorizedRoot: authorizedRoot) { value in
                    coordinator.completeReply(value)
                }
            }
        }
        let boundedTimeout = max(0.001, min(60, timeout))
        let waitResult = coordinator.wait(timeout: boundedTimeout)
        if waitResult == .timedOut {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service request timed out"
            )
        }
        let returnedResponse = coordinator.terminalResponse
        connection.invalidate()
        if let returnedResponse { return returnedResponse }
        return ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service did not return a result"
        )
    }

    func queryTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemTransactionStatus {
        guard let configuration = authenticatedPeerConfiguration() else {
            return unavailableStatus(
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "The packaged secure filesystem service identity is unavailable"
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemServiceXPC.self
        )
        connection.setCodeSigningRequirement(configuration.signingRequirement)
        let coordinator = SecureFilesystemStatusHandshakeCoordinator(
            transactionID: request.transactionID
        )
        connection.interruptionHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was interrupted"
            )
        }
        connection.invalidationHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was invalidated"
            )
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let failure = Self.connectionFailure(error)
            coordinator.completeWithoutReply(code: failure.code, message: failure.message)
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return unavailableStatus(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            let disposition = coordinator.receiveServiceInfo(
                information,
                allowedCodeDirectoryHashes: configuration.allowedCodeDirectoryHashes
            )
            guard disposition == .prepareDispatch else { return }
            _ = coordinator.dispatchIfAuthorized {
                proxy.queryTransaction(request, authorizedRoot: authorizedRoot) { value in
                    coordinator.completeReply(value)
                }
            }
        }
        let boundedTimeout = max(0.001, min(60, timeout))
        if coordinator.wait(timeout: boundedTimeout) == .timedOut {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service request timed out"
            )
        }
        let returnedStatus = coordinator.terminalStatus
        connection.invalidate()
        return returnedStatus ?? unavailableStatus(
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service did not return transaction status"
        )
    }

    func resumeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        performTransactionControl(
            request: request,
            authorizedRoot: authorizedRoot,
            timeout: timeout
        ) { proxy, reply in
            proxy.resumeTransaction(request, authorizedRoot: authorizedRoot, withReply: reply)
        }
    }

    func acknowledgeTransaction(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        performTransactionControl(
            request: request,
            authorizedRoot: authorizedRoot,
            timeout: timeout
        ) { proxy, reply in
            proxy.acknowledgeTransaction(
                request,
                authorizedRoot: authorizedRoot,
                withReply: reply
            )
        }
    }

    private func performTransactionControl(
        request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval,
        submit: @escaping (
            ForgeFilesystemServiceXPC,
            @escaping (ForgeFilesystemResponse) -> Void
        ) -> Void
    ) -> ForgeFilesystemResponse {
        guard let configuration = authenticatedPeerConfiguration() else {
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "The packaged secure filesystem service identity is unavailable"
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemServiceXPC.self
        )
        connection.setCodeSigningRequirement(configuration.signingRequirement)
        let coordinator = SecureFilesystemHandshakeCoordinator(
            transactionID: request.transactionID
        )
        connection.interruptionHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was interrupted"
            )
        }
        connection.invalidationHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was invalidated"
            )
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let failure = Self.connectionFailure(error)
            coordinator.completeWithoutReply(code: failure.code, message: failure.message)
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            let disposition = coordinator.receiveServiceInfo(
                information,
                allowedCodeDirectoryHashes: configuration.allowedCodeDirectoryHashes
            )
            guard disposition == .prepareDispatch else { return }
            _ = coordinator.dispatchIfAuthorized {
                submit(proxy) { value in coordinator.completeReply(value) }
            }
        }
        let boundedTimeout = max(0.001, min(60, timeout))
        if coordinator.wait(timeout: boundedTimeout) == .timedOut {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service request timed out"
            )
        }
        let returnedResponse = coordinator.terminalResponse
        connection.invalidate()
        return returnedResponse ?? ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service did not return a result"
        )
    }

    private func authenticatedPeerConfiguration() -> (
        allowedCodeDirectoryHashes: [String],
        signingRequirement: String
    )? {
        guard let securedInfo = ForgeFilesystemCodeIdentity.currentSecuredInfoDictionary(),
              let allowedCodeDirectoryHashes = ForgeFilesystemCodeIdentity
                  .daemonCodeDirectoryHashes(inSecuredInfoDictionary: securedInfo),
              let signingRequirement = ForgeFilesystemProtocolConstants
                  .requiredDaemonCodeSigningRequirement(
                      codeDirectoryHashes: allowedCodeDirectoryHashes
                  ) else {
            return nil
        }
        return (allowedCodeDirectoryHashes, signingRequirement)
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

    private static func connectionFailure(_ error: Error) -> (code: String, message: String) {
        let description = error.localizedDescription.lowercased()
        let identityFailure = description.contains("code sign")
            || description.contains("requirement")
        return identityFailure
            ? (
                ForgeFilesystemErrorCode.helperIdentityMismatch,
                "Secure filesystem service identity validation failed"
            )
            : (
                ForgeFilesystemErrorCode.helperUnavailable,
                "Secure filesystem service connection failed"
            )
    }

    /// Once a request has been submitted to XPC, losing the reply does not prove
    /// that the daemon failed before capture or commit. Preserve the caller's
    /// transaction identity so retry/recovery can query the same durable record.
    static func uncertainFailure(
        for request: ForgeFilesystemMutationRequest,
        code: String,
        message: String
    ) -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: false,
            code: code,
            message: message,
            recoveryTransactionID: request.transactionID
        )
    }
}

final class SecureFilesystemMutationClient: @unchecked Sendable {
    private let transport: any SecureFilesystemServiceTransport

    init(transport: any SecureFilesystemServiceTransport = XPCSecureFilesystemServiceTransport()) {
        self.transport = transport
    }

    func deleteLeaf(
        at url: URL,
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?,
        recoveryLedger: SecureFilesystemRecoveryLedger,
        authorityValidator: @Sendable (ToolInvocationContext) throws -> Void = { _ in },
        retentionAttemptObserver: (@Sendable () -> Void)? = nil
    ) throws -> ToolResult {
        guard let context else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Protected filesystem mutation requires a durable project context"
            )
        }
        switch transport.serviceStatus() {
        case .enabled:
            break
        case .requiresApproval:
            return .failure(
                code: ForgeFilesystemErrorCode.helperNotApproved,
                message: "Secure filesystem service requires approval in System Settings",
                retryable: true
            )
        case .notRegistered, .notFound:
            return .failure(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service is unavailable",
                retryable: true
            )
        }
        try cancellation?.checkCancellation()
        let operationalProbe = transport.operationalProbe(
            timeout: min(2, max(0.001, cancellation?.remainingTimeInterval ?? 2))
        )
        guard operationalProbe.operational else {
            return .failure(
                code: operationalProbe.code,
                message: operationalProbe.message,
                retryable: operationalProbe.code == ForgeFilesystemErrorCode.helperUnavailable
            )
        }
        retentionAttemptObserver?()
        let reconciliation = reconcileRecoveryLedger(
            recoveryLedger: recoveryLedger,
            cancellation: cancellation,
            purgeTerminalReceipts: true
        )
        guard reconciliation.available else {
            return .failure(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "Protected filesystem recovery debt could not be verified"
            )
        }
        guard reconciliation.retainedCount < SecureFilesystemRecoveryLedger.maximumRecords else {
            var result = ToolResult.failure(
                code: ForgeFilesystemErrorCode.protectedNamespaceUnavailable,
                message: "Protected filesystem recovery is full; reconcile or recover retained transactions before another mutation"
            )
            result.payload["recovery_debt_count"] = reconciliation.retainedCount
            result.payload["recovery_debt_capacity"] =
                SecureFilesystemRecoveryLedger.maximumRecords
            return result
        }
        let requestedTarget = url.standardizedFileURL
        guard let target = Self.canonicalizedLeafPath(requestedTarget) else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Filesystem leaf parent cannot be canonicalized"
            )
        }
        let writableRoots = context.authorizationScope.writableRoots.compactMap { declaredRoot in
            Self.canonicalExistingDirectory(declaredRoot)
        }
        .filter { Self.contains(target, root: $0) }
        .sorted { $0.pathComponents.count > $1.pathComponents.count }
        guard let root = writableRoots.first,
              target != root else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "No authorized writable project root contains the requested leaf"
            )
        }
        let relativeComponents = Array(
            target.pathComponents.dropFirst(root.pathComponents.count)
        )
        let rootDescriptor = Self.openPinnedDirectory(root)
        guard rootDescriptor >= 0 else {
            let rootOpenError = errno
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Authorized project root cannot be opened: \(String(cString: strerror(rootOpenError)))"
            )
        }
        let rootHandle = FileHandle(fileDescriptor: rootDescriptor, closeOnDealloc: true)
        defer { try? rootHandle.close() }
        var rootInformation = stat()
        guard Darwin.fstat(rootDescriptor, &rootInformation) == 0 else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Authorized project root identity cannot be read"
            )
        }
        var leafInformation = stat()
        guard Darwin.lstat(target.path, &leafInformation) == 0 else {
            return .failure(code: "not_found", message: "Filesystem leaf does not exist")
        }
        guard leafInformation.st_mode & S_IFMT != S_IFDIR else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Directory deletion is disabled until privileged recursive recovery is qualified"
            )
        }
        let requestID = cancellation?.requestID ?? UUID()
        let request = ForgeFilesystemMutationRequest(
            requestID: requestID.uuidString.lowercased(),
            transactionID: UUID().uuidString.lowercased(),
            projectID: context.projectID.description,
            projectGeneration: context.projectGeneration.rawValue,
            rootID: "\(UInt64(rootInformation.st_dev)):\(UInt64(rootInformation.st_ino))",
            rootIdentity: Self.identity(rootInformation),
            relativePathComponents: relativeComponents,
            access: .deleteLeaf,
            contract: .currentEntry
        )
        if let errorCode = request.validationError() {
            return .failure(
                code: errorCode,
                message: "Protected filesystem request is invalid"
            )
        }
        do {
            try recoveryLedger.retain(
                SecureFilesystemRecoveryRecord(
                    request: request,
                    originatingClientID: context.clientID,
                    rootPath: root.path
                ),
                validatingCurrentAuthority: {
                    try authorityValidator(context)
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is ToolCallDeadlineExceeded {
            throw ToolCallDeadlineExceeded()
        } catch let error as ProjectContextError {
            return .failure(
                code: error.code,
                message: error.localizedDescription
            )
        } catch {
            return .failure(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "Protected filesystem recovery authority could not be retained"
            )
        }
        let timeout = min(
            60,
            max(0.001, cancellation?.remainingTimeInterval ?? 60)
        )
        let response = transport.deleteLeaf(
            request: request,
            authorizedRoot: rootHandle,
            timeout: timeout
        )
        guard Self.responseMatchesTransaction(
            response,
            transactionID: request.transactionID,
            terminalRequiresAcknowledgement: true
        ) else {
            var result = ToolResult.failure(
                code: ForgeFilesystemErrorCode.protocolMismatch,
                message: "Secure filesystem service returned mismatched transaction identity"
            )
            result.payload["recovery_required"] = true
            result.payload["filesystem_transaction_id"] = request.transactionID
            return result
        }
        var callerCleanupRequired = false
        if !response.acknowledgementRequired,
           response.recoveryTransactionID == nil {
            do {
                _ = try recoveryLedger.remove(transactionID: request.transactionID)
            } catch {
                callerCleanupRequired = true
            }
        }
        if response.ok {
            var payload: [String: Any] = [
                "path": target.path,
                "deleted": true,
                "deleted_entries": 1,
                "committed": response.committed,
                "durability_confirmed": response.durabilityConfirmed,
                "filesystem_transaction_id": response.recoveryTransactionID
                    ?? request.transactionID,
                "acknowledgement_required": response.acknowledgementRequired,
            ]
            if callerCleanupRequired { payload["caller_cleanup_required"] = true }
            return .success(payload)
        }
        var result = ToolResult.failure(
            code: response.code,
            message: response.message,
            retryable: response.code == ForgeFilesystemErrorCode.helperUnavailable
                || response.code == ForgeFilesystemErrorCode.helperNotApproved
        )
        if let recoveryTransactionID = response.recoveryTransactionID {
            result.payload["recovery_required"] = true
            result.payload["filesystem_transaction_id"] = recoveryTransactionID
        }
        result.payload["acknowledgement_required"] = response.acknowledgementRequired
        if callerCleanupRequired { result.payload["caller_cleanup_required"] = true }
        result.payload["committed"] = response.committed
        result.payload["durability_confirmed"] = response.durabilityConfirmed
        return result
    }

    func recoverDelete(
        transactionID: String,
        action: String,
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?,
        recoveryLedger: SecureFilesystemRecoveryLedger
    ) throws -> ToolResult {
        guard let context else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Protected filesystem recovery requires a durable project context"
            )
        }
        guard let recoveryAction = RecoveryAction(rawValue: action),
              let transactionUUID = UUID(uuidString: transactionID) else {
            return .failure(
                code: ForgeFilesystemErrorCode.invalidRequest,
                message: "A valid transaction_id and recovery action are required"
            )
        }
        try cancellation?.checkCancellation()
        let normalizedTransactionID = transactionUUID.uuidString.lowercased()
        let record: SecureFilesystemRecoveryRecord
        do {
            guard let retained = try recoveryLedger.record(
                transactionID: normalizedTransactionID
            ) else {
                return .failure(
                    code: ForgeFilesystemErrorCode.transactionUnavailable,
                    message: "Protected filesystem recovery authority is not retained"
                )
            }
            record = retained
        } catch {
            return .failure(
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "Protected filesystem recovery authority is unavailable"
            )
        }
        guard record.requesterUID == UInt32(geteuid()),
              record.projectID.caseInsensitiveCompare(
                  context.projectID.description
              ) == .orderedSame,
              record.projectGeneration == context.projectGeneration.rawValue else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Protected filesystem recovery authority does not match this project generation"
            )
        }
        guard let rootHandle = Self.reopenAuthorizedRoot(
            for: record,
            context: context
        ) else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The retained protected filesystem root is no longer authorized"
            )
        }
        defer { try? rootHandle.close() }
        let request = ForgeFilesystemTransactionControlRequest(
            transactionID: record.transactionID,
            projectID: record.projectID,
            projectGeneration: record.projectGeneration,
            rootID: record.rootID,
            rootIdentity: record.rootIdentity.protocolIdentity
        )
        guard request.validationError() == nil else {
            return .failure(
                code: ForgeFilesystemErrorCode.invalidRequest,
                message: "The retained protected filesystem recovery request is invalid"
            )
        }
        let timeout = min(
            60,
            max(0.001, cancellation?.remainingTimeInterval ?? 60)
        )

        switch recoveryAction {
        case .query:
            let status = transport.queryTransaction(
                request: request,
                authorizedRoot: rootHandle,
                timeout: timeout
            )
            guard status.validationError() == nil else {
                return .failure(
                    code: ForgeFilesystemErrorCode.protocolMismatch,
                    message: "Secure filesystem service returned invalid transaction status"
                )
            }
            guard status.transactionID == nil
                    || status.transactionID?.caseInsensitiveCompare(
                        record.transactionID
                    ) == .orderedSame else {
                return .failure(
                    code: ForgeFilesystemErrorCode.protocolMismatch,
                    message: "Secure filesystem service returned mismatched transaction status"
                )
            }
            var payload = Self.statusPayload(status, requestedTransactionID: record.transactionID)
            if status.disposition == .unavailable {
                var result = ToolResult.failure(
                    code: status.code,
                    message: status.message,
                    retryable: status.code == ForgeFilesystemErrorCode.helperUnavailable
                )
                result.payload.merge(payload) { _, value in value }
                return result
            }
            payload["ok"] = true
            return .success(payload)

        case .resume:
            let response = transport.resumeTransaction(
                request: request,
                authorizedRoot: rootHandle,
                timeout: timeout
            )
            guard Self.responseMatchesTransaction(
                response,
                transactionID: record.transactionID,
                terminalRequiresAcknowledgement: true
            ) else {
                return .failure(
                    code: ForgeFilesystemErrorCode.protocolMismatch,
                    message: "Secure filesystem service returned mismatched transaction identity"
                )
            }
            return Self.toolResult(
                response,
                transactionID: record.transactionID
            )

        case .acknowledge:
            let response = transport.acknowledgeTransaction(
                request: request,
                authorizedRoot: rootHandle,
                timeout: timeout
            )
            guard Self.responseMatchesTransaction(
                response,
                transactionID: record.transactionID,
                terminalRequiresAcknowledgement: false
            ) else {
                return .failure(
                    code: ForgeFilesystemErrorCode.protocolMismatch,
                    message: "Secure filesystem service returned mismatched transaction identity"
                )
            }
            guard response.ok, response.durabilityConfirmed else {
                return Self.toolResult(
                    response,
                    transactionID: record.transactionID
                )
            }
            do {
                _ = try recoveryLedger.remove(transactionID: record.transactionID)
            } catch {
                return .failure(
                    code: ForgeFilesystemErrorCode.transactionUnavailable,
                    message: "The daemon acknowledged the transaction but caller cleanup must be retried",
                    retryable: true
                )
            }
            return .success([
                "transaction_id": record.transactionID,
                "action": RecoveryAction.acknowledge.rawValue,
                "acknowledged": true,
                "durability_confirmed": true,
                "acknowledgement_required": false,
            ])
        }
    }

    /// Bounded startup/pre-mutation reconciliation. This deliberately does not
    /// resume a nonterminal delete or restore a quarantined leaf. It only asks
    /// the authenticated daemon to acknowledge terminal or absent transactions,
    /// then releases caller authority if the exact retained record still matches.
    func reconcileRecoveryLedger(
        recoveryLedger: SecureFilesystemRecoveryLedger,
        cancellation: ToolCallCancellation?,
        purgeTerminalReceipts: Bool,
        maximumSeconds: TimeInterval = 5
    ) -> SecureFilesystemRecoveryReconciliation {
        let initialRecords: [SecureFilesystemRecoveryRecord]
        do {
            if purgeTerminalReceipts {
                initialRecords = try recoveryLedger.records()
            } else {
                initialRecords = try recoveryLedger.snapshotRecords()
            }
        } catch {
            return .unavailable
        }
        guard purgeTerminalReceipts, !initialRecords.isEmpty else {
            return SecureFilesystemRecoveryReconciliation(
                retainedCount: initialRecords.count,
                releasedCount: 0,
                available: true
            )
        }

        let boundedSeconds = max(0.001, min(10, maximumSeconds))
        let deadline = Date().addingTimeInterval(
            min(boundedSeconds, cancellation?.remainingTimeInterval ?? boundedSeconds)
        )
        var releasedCount = 0
        for record in initialRecords {
            do {
                try cancellation?.checkCancellation()
            } catch {
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0,
                  record.requesterUID == UInt32(geteuid()),
                  let queryRoot = Self.reopenRetainedRoot(for: record) else {
                continue
            }
            let request = ForgeFilesystemTransactionControlRequest(
                transactionID: record.transactionID,
                projectID: record.projectID,
                projectGeneration: record.projectGeneration,
                rootID: record.rootID,
                rootIdentity: record.rootIdentity.protocolIdentity
            )
            guard request.validationError() == nil else {
                try? queryRoot.close()
                continue
            }
            let queryTimeout = min(1, max(0.001, remaining))
            let status = transport.queryTransaction(
                request: request,
                authorizedRoot: queryRoot,
                timeout: queryTimeout
            )
            try? queryRoot.close()
            guard status.validationError() == nil,
                  status.transactionID == nil
                    || status.transactionID?.caseInsensitiveCompare(
                        record.transactionID
                    ) == .orderedSame else {
                continue
            }
            let canPurgeTerminal = status.terminal
                && status.acknowledgementRequired
                && !status.recoveryRequired
            let canFinishMissingOrAcknowledging = status.disposition == .unavailable
                && status.code == ForgeFilesystemErrorCode.transactionUnavailable
            guard canPurgeTerminal || canFinishMissingOrAcknowledging,
                  deadline.timeIntervalSinceNow > 0,
                  let acknowledgeRoot = Self.reopenRetainedRoot(for: record) else {
                continue
            }
            let response = transport.acknowledgeTransaction(
                request: request,
                authorizedRoot: acknowledgeRoot,
                timeout: min(1, max(0.001, deadline.timeIntervalSinceNow))
            )
            try? acknowledgeRoot.close()
            guard Self.responseMatchesTransaction(
                response,
                transactionID: record.transactionID,
                terminalRequiresAcknowledgement: false
            ), response.ok,
               response.durabilityConfirmed,
               !response.acknowledgementRequired else {
                continue
            }
            do {
                if try recoveryLedger.remove(
                    transactionID: record.transactionID,
                    ifMatching: record
                ) {
                    releasedCount += 1
                }
            } catch {
                continue
            }
        }

        do {
            return SecureFilesystemRecoveryReconciliation(
                retainedCount: try recoveryLedger.records().count,
                releasedCount: releasedCount,
                available: true
            )
        } catch {
            return .unavailable
        }
    }

    private enum RecoveryAction: String {
        case query
        case resume
        case acknowledge
    }

    private static func toolResult(
        _ response: ForgeFilesystemResponse,
        transactionID: String
    ) -> ToolResult {
        let payload: [String: Any] = [
            "filesystem_transaction_id": response.recoveryTransactionID ?? transactionID,
            "committed": response.committed,
            "durability_confirmed": response.durabilityConfirmed,
            "recovery_required": response.recoveryTransactionID != nil
                && !response.acknowledgementRequired,
            "acknowledgement_required": response.acknowledgementRequired,
        ]
        if response.ok { return .success(payload) }
        var result = ToolResult.failure(
            code: response.code,
            message: response.message,
            retryable: response.code == ForgeFilesystemErrorCode.helperUnavailable
        )
        result.payload.merge(payload) { _, value in value }
        return result
    }

    private static func responseMatchesTransaction(
        _ response: ForgeFilesystemResponse,
        transactionID: String,
        terminalRequiresAcknowledgement: Bool
    ) -> Bool {
        if let returnedID = response.recoveryTransactionID,
           returnedID.caseInsensitiveCompare(transactionID) != .orderedSame {
            return false
        }
        if response.acknowledgementRequired {
            guard response.recoveryTransactionID != nil else { return false }
        }
        if terminalRequiresAcknowledgement,
           response.ok || response.committed || response.durabilityConfirmed {
            guard response.durabilityConfirmed,
                  response.recoveryTransactionID != nil else {
                return false
            }
            if !response.acknowledgementRequired {
                guard !response.ok, !response.committed else { return false }
            }
        }
        return true
    }

    private static func statusPayload(
        _ status: ForgeFilesystemTransactionStatus,
        requestedTransactionID: String
    ) -> [String: Any] {
        let disposition: String
        switch status.disposition {
        case .unavailable: disposition = "unavailable"
        case .recoveryRequired: disposition = "recovery_required"
        case .committed: disposition = "committed"
        case .restored: disposition = "restored"
        case .rejected: disposition = "rejected"
        case .quarantined: disposition = "quarantined"
        case .conflicted: disposition = "conflicted"
        case nil: disposition = "invalid"
        }
        return [
            "transaction_id": status.transactionID ?? requestedTransactionID,
            "disposition": disposition,
            "code": status.code,
            "message": status.message,
            "terminal": status.terminal,
            "committed": status.committed,
            "durability_confirmed": status.durabilityConfirmed,
            "recovery_required": status.recoveryRequired,
            "acknowledgement_required": status.acknowledgementRequired,
        ]
    }

    private static func reopenAuthorizedRoot(
        for record: SecureFilesystemRecoveryRecord,
        context: ToolInvocationContext
    ) -> FileHandle? {
        let candidates = context.authorizationScope.writableRoots.compactMap {
            canonicalExistingDirectory($0)
        }
        .sorted { lhs, rhs in
            if lhs.path == record.rootPath { return true }
            if rhs.path == record.rootPath { return false }
            return lhs.path < rhs.path
        }
        for candidate in candidates {
            let descriptor = openPinnedDirectory(candidate)
            guard descriptor >= 0 else { continue }
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                  record.rootIdentity.matchesRoot(information),
                  record.rootID == "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))" else {
                _ = Darwin.close(descriptor)
                continue
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        return nil
    }

    private static func reopenRetainedRoot(
        for record: SecureFilesystemRecoveryRecord
    ) -> FileHandle? {
        guard record.requesterUID == UInt32(geteuid()),
              let canonicalRoot = canonicalExistingDirectory(
                  URL(fileURLWithPath: record.rootPath, isDirectory: true)
              ),
              canonicalRoot.path == record.rootPath else {
            return nil
        }
        let descriptor = openPinnedDirectory(canonicalRoot)
        guard descriptor >= 0 else { return nil }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              record.rootIdentity.matchesRoot(information),
              record.rootID == "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))" else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func identity(_ information: stat) -> ForgeFilesystemIdentity {
        ForgeFilesystemIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            owner: UInt32(information.st_uid),
            group: UInt32(information.st_gid),
            linkCount: UInt64(information.st_nlink)
        )
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func canonicalizedLeafPath(_ url: URL) -> URL? {
        guard !url.lastPathComponent.isEmpty,
              let parent = canonicalExistingDirectory(url.deletingLastPathComponent()) else {
            return nil
        }
        return parent.appendingPathComponent(url.lastPathComponent)
    }

    private static func canonicalExistingDirectory(_ url: URL) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                Darwin.realpath(source, destination.baseAddress) != nil
            }
        }
        guard resolved else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private static func openPinnedDirectory(_ url: URL) -> Int32 {
        let rootDescriptor = Darwin.open(
            "/",
            O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard rootDescriptor >= 0 else { return -1 }
        var currentDescriptor = rootDescriptor
        for componentSlice in url.path.split(separator: "/") {
            let component = String(componentSlice)
            guard !component.isEmpty, component != ".", component != ".." else {
                Darwin.close(currentDescriptor)
                errno = EINVAL
                return -1
            }
            let nextDescriptor = component.withCString { componentPointer in
                Darwin.openat(
                    currentDescriptor,
                    componentPointer,
                    O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                )
            }
            guard nextDescriptor >= 0 else {
                let openError = errno
                Darwin.close(currentDescriptor)
                errno = openError
                return -1
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }
}

private enum SecureFilesystemOperationalLifecycle {
    static func evaluate(
        registrationStatus: SecureFilesystemServiceStatus,
        paths: AppPaths,
        transport: any SecureFilesystemServiceTransport,
        reconcile: Bool
    ) -> SecureFilesystemOperationalHealth {
        let operationalState: SecureFilesystemServiceOperationalState
        let daemonOperational: Bool
        switch registrationStatus {
        case .enabled:
            let probe = transport.operationalProbe(timeout: 2)
            daemonOperational = probe.operational
            operationalState = probe.operational ? .operational : .registeredUnavailable
        case .requiresApproval:
            daemonOperational = false
            operationalState = .requiresApproval
        case .notRegistered:
            daemonOperational = false
            operationalState = .notRegistered
        case .notFound:
            daemonOperational = false
            operationalState = .notPackaged
        }

        let localStatus: FilesystemQuarantineLedgerStatus?
        do {
            let ledger = FilesystemQuarantineLedger(paths: paths)
            localStatus = reconcile
                ? try ledger.status()
                : try ledger.snapshotStatus()
        } catch {
            localStatus = nil
        }

        let privilegedStatus = SecureFilesystemMutationClient(
            transport: transport
        ).reconcileRecoveryLedger(
            recoveryLedger: SecureFilesystemRecoveryLedger(paths: paths),
            cancellation: nil,
            purgeTerminalReceipts: reconcile && daemonOperational
        )
        return SecureFilesystemOperationalHealth(
            registrationStatus: registrationStatus,
            operationalState: operationalState,
            localQuarantineOccupied: localStatus?.occupiedCount ?? 0,
            localQuarantineCapacity: FilesystemQuarantineLedger.maximumReservations,
            privilegedRecoveryRetained: privilegedStatus.retainedCount,
            privilegedRecoveryCapacity: SecureFilesystemRecoveryLedger.maximumRecords,
            releasedDuringReconciliation: (localStatus?.releasedCount ?? 0)
                + privilegedStatus.releasedCount,
            debtStatusAvailable: localStatus != nil && privilegedStatus.available
        )
    }
}

import Foundation

/// Capacity identity only. A permit never grants project, task or tool authority.
enum NativeProviderWorkOwner: Hashable, Sendable {
    case managed(RunID)
    case source(taskID: UUID, requestID: UUID)
}

struct NativeProviderWorkPermit: Sendable, Equatable {
    fileprivate let poolID: UUID
    fileprivate let token: UUID

    fileprivate init(poolID: UUID, token: UUID) {
        self.poolID = poolID
        self.token = token
    }
}

/// One manager owns this bounded pool across source and managed coordinators.
/// Acquisition never waits or queues; owners retain permits until their work exits.
final class NativeProviderWorkAdmission: @unchecked Sendable {
    let limit: Int
    private let poolID = UUID()
    private let lock = NSLock()
    private var open = true
    private var owners: [UUID: NativeProviderWorkOwner] = [:]

    init(limit: Int) throws {
        guard (1...16).contains(limit) else {
            throw AutonomyError.invalidRequest("provider work limit must be between 1 and 16")
        }
        self.limit = limit
    }

    func tryAcquire(owner: NativeProviderWorkOwner) -> NativeProviderWorkPermit? {
        lock.lock()
        defer { lock.unlock() }
        guard open, owners.count < limit, !owners.values.contains(owner) else { return nil }
        let token = UUID()
        owners[token] = owner
        return NativeProviderWorkPermit(poolID: poolID, token: token)
    }

    @discardableResult
    func release(_ permit: NativeProviderWorkPermit) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard permit.poolID == poolID else { return false }
        return owners.removeValue(forKey: permit.token) != nil
    }

    /// Closing admission never forgets an owner and cannot be reversed.
    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return owners.count
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }
}

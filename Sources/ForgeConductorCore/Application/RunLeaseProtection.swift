// Shared operation/renewal ownership for ordinary and source-bootstrap runs.

import Foundation

enum RunLeaseProtection {
    static func withRenewal<Value: Sendable>(
        _ initialLease: RunLease,
        repository: ProjectControlPlaneRepository,
        policy: RunLeasePolicy,
        sleeper: any AutonomySleeping,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (value: Value, lease: RunLease) {
        let leaseState = RunLeaseState(initialLease)
        return try await withThrowingTaskGroup(of: LeaseProtectedEvent<Value>.self) { group in
            group.addTask {
                .value(try await operation())
            }
            group.addTask {
                while !Task.isCancelled {
                    try await sleeper.sleep(for: .seconds(policy.renewalInterval))
                    try Task.checkCancellation()
                    let current = await leaseState.current()
                    let renewed = try await repository.renewRunLease(current, policy: policy)
                    await leaseState.update(renewed)
                }
                throw CancellationError()
            }
            do {
                guard let first = try await group.next() else {
                    throw AutonomyError.leaseRequired
                }
                switch first {
                case .value(let value):
                    group.cancelAll()
                    do {
                        while try await group.next() != nil {}
                    } catch is CancellationError {
                        // Expected when completion cancels the renewal owner.
                    }
                    return (value, await leaseState.current())
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

private enum LeaseProtectedEvent<Value: Sendable>: Sendable {
    case value(Value)
}

private actor RunLeaseState {
    private var lease: RunLease
    init(_ lease: RunLease) { self.lease = lease }
    func current() -> RunLease { lease }
    func update(_ lease: RunLease) { self.lease = lease }
}

import Foundation
import XCTest
@testable import ForgeConductorCore

final class NativeProviderWorkAdmissionTests: XCTestCase {
    func testBoundsForeignReleaseReplayAndIrreversibleClose() throws {
        XCTAssertThrowsError(try NativeProviderWorkAdmission(limit: 0))
        XCTAssertThrowsError(try NativeProviderWorkAdmission(limit: 17))
        let pool = try NativeProviderWorkAdmission(limit: 1)
        let other = try NativeProviderWorkAdmission(limit: 1)
        let owner = NativeProviderWorkOwner.source(taskID: UUID(), requestID: UUID())
        let first = try XCTUnwrap(pool.tryAcquire(owner: owner))
        let foreign = try XCTUnwrap(other.tryAcquire(owner: .managed(RunID())))
        XCTAssertNil(pool.tryAcquire(owner: owner))
        XCTAssertNil(pool.tryAcquire(owner: .managed(RunID())))
        XCTAssertFalse(pool.release(foreign))
        XCTAssertEqual(pool.activeCount, 1)
        XCTAssertTrue(pool.release(first))
        let successor = try XCTUnwrap(pool.tryAcquire(owner: .managed(RunID())))
        XCTAssertFalse(pool.release(first), "A replay cannot release newer capacity")
        XCTAssertEqual(pool.activeCount, 1)
        pool.close()
        pool.close()
        XCTAssertFalse(pool.isOpen)
        XCTAssertEqual(pool.activeCount, 1, "Closing must retain actual owners")
        XCTAssertTrue(pool.release(successor))
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertNil(pool.tryAcquire(owner: owner), "Late release must not reopen admission")
        XCTAssertTrue(other.release(foreign))
    }

    func testConcurrentAcquisitionSharesOneBoundAndOneExactOwner() async throws {
        let pool = try NativeProviderWorkAdmission(limit: 4)
        let permits = await withTaskGroup(of: NativeProviderWorkPermit?.self) { group in
            for index in 0..<64 {
                group.addTask {
                    let owner: NativeProviderWorkOwner = index.isMultiple(of: 2)
                        ? .managed(RunID()) : .source(taskID: UUID(), requestID: UUID())
                    return pool.tryAcquire(owner: owner)
                }
            }
            var retained: [NativeProviderWorkPermit] = []
            for await permit in group { if let permit { retained.append(permit) } }
            return retained
        }
        XCTAssertEqual(permits.count, 4)
        XCTAssertEqual(pool.activeCount, 4)
        for permit in permits { XCTAssertTrue(pool.release(permit)) }
        let owner = NativeProviderWorkOwner.source(taskID: UUID(), requestID: UUID())
        let duplicates = await withTaskGroup(of: NativeProviderWorkPermit?.self) { group in
            for _ in 0..<64 { group.addTask { pool.tryAcquire(owner: owner) } }
            var retained: [NativeProviderWorkPermit] = []
            for await permit in group { if let permit { retained.append(permit) } }
            return retained
        }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(pool.activeCount, 1)
        for permit in duplicates { XCTAssertTrue(pool.release(permit)) }
        XCTAssertEqual(pool.activeCount, 0)
    }
}

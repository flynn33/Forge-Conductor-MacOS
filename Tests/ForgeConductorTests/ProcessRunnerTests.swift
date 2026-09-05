// ProcessRunnerTests.swift
// Verifies bounded subprocess completion, timeout escalation, and output capture.

import Darwin
import XCTest
@testable import ForgeConductorCore

final class ProcessRunnerTests: XCTestCase {
    private func fastRunner() -> ProcessRunner {
        ProcessRunner(terminationGraceSec: 0.05, forcedTerminationGraceSec: 0.5)
    }

    func testNormalAndNonzeroExitStatuses() throws {
        let runner = fastRunner()

        let success = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
        XCTAssertEqual(success.exitCode, 0)
        XCTAssertFalse(success.timedOut)

        let failure = try runner.run(executable: "/usr/bin/false", timeoutSec: 1)
        XCTAssertEqual(failure.exitCode, 1)
        XCTAssertFalse(failure.timedOut)
    }

    func testLaunchFailureDoesNotPoisonTheNextRun() throws {
        let runner = fastRunner()

        XCTAssertThrowsError(
            try runner.run(executable: "/forge-conductor-tests/missing-executable")
        )

        let recovery = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
        XCTAssertEqual(recovery.exitCode, 0)
        XCTAssertFalse(recovery.timedOut)
    }

    func testTimeoutTerminatesChildAndReturnsConfirmedStatus() throws {
        let started = ContinuousClock.now
        let result = try fastRunner().run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeoutSec: 0.02
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testNonfiniteTimeoutCannotCreateAnIndefiniteWait() throws {
        for timeout in [TimeInterval.infinity, TimeInterval.nan, -TimeInterval.infinity] {
            let started = ContinuousClock.now
            let result = try fastRunner().run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeoutSec: timeout
            )

            XCTAssertTrue(result.timedOut)
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        }
    }

    func testTermIgnoringChildRequiresSIGKILL() throws {
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf 'ready\\n'; while :; do :; done"],
            timeoutSec: 0.25
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, SIGKILL)
        XCTAssertEqual(result.stdout, "ready\n")
    }

    func testOutputIsCapturedConcurrentlyAndTruncatedPerStream() throws {
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf '%010240d' 0; printf '%010240d' 0 >&2",
            ],
            timeoutSec: 2,
            maximumOutputBytes: 256
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.utf8.count, 256)
        XCTAssertEqual(result.stderr.utf8.count, 256)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testCallerCannotRaiseTheOwnerOutputCeiling() throws {
        let runner = ProcessRunner(
            terminationGraceSec: 0.05,
            forcedTerminationGraceSec: 0.5,
            maximumRetainedOutputBytes: 32
        )
        let result = try runner.run(
            executable: "/usr/bin/printf",
            arguments: [String(repeating: "x", count: 256)],
            timeoutSec: 1,
            maximumOutputBytes: .max
        )

        XCTAssertEqual(result.stdout.utf8.count, 32)
        XCTAssertTrue(result.stdoutTruncated)
    }

    func testSaturatedStreamsContinueDrainingAfterRetentionCapUntilFiniteChildCompletes() throws {
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", """
                (/usr/bin/head -c 524288 /dev/zero; printf 'stdout-complete') &
                (/usr/bin/head -c 524288 /dev/zero >&2; printf 'stderr-complete' >&2) &
                wait
                """],
            timeoutSec: 3,
            maximumOutputBytes: 64
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.utf8.count, 64)
        XCTAssertEqual(result.stderr.utf8.count, 64)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testContinuousOutputDoesNotStarveOtherStreamOrTimeout() throws {
        let started = ContinuousClock.now
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "while :; do printf '%016384d' 0; printf 'stderr-progress\\n' >&2; done"],
            timeoutSec: 0.1,
            maximumOutputBytes: 64
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderr.contains("stderr-progress"))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testTerminationGraceDrainsHandlerOutputBeyondPipeCapacity() throws {
        let result = try ProcessRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", """
                trap 'printf "%0200000d" 0; printf "grace-completed" >&2; exit 0' TERM
                printf 'ready'
                while :; do :; done
                """],
            timeoutSec: 0.1,
            maximumOutputBytes: 64
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 0, "A finite TERM flush should finish during the normal grace window")
        XCTAssertEqual(result.stderr, "grace-completed")
        XCTAssertTrue(result.stdoutTruncated)
    }

    func testDirectChildExitDoesNotWaitForDescendantPipeEOF() throws {
        let started = ContinuousClock.now
        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 3 & printf '%d\\n' $!"],
            timeoutSec: 1
        )
        let elapsed = started.duration(to: .now)
        let descendantPID = try XCTUnwrap(
            Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(processExists(descendantPID))
    }

    func testCancellationTerminatesAndReapsEntireProcessGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let descendantFile = directory.appendingPathComponent("descendant.pid")
        let cancellation = ToolCallCancellation()
        let runner = fastRunner()
        let result = LockedProcessResult()
        let completed = DispatchGroup()
        completed.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            result.store(Result {
                try runner.run(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        trap '' TERM
                        printf '%d' "$$" > "$LEADER_FILE"
                        (
                          trap '' TERM
                          while :; do /bin/sleep 1; done
                        ) &
                        printf '%d' "$!" > "$DESCENDANT_FILE"
                        while :; do /bin/sleep 1; done
                        """,
                    ],
                    environment: [
                        "LEADER_FILE": leaderFile.path,
                        "DESCENDANT_FILE": descendantFile.path,
                    ],
                    timeoutSec: 5,
                    cancellation: cancellation
                )
            })
        }

        let leaderPID = try XCTUnwrap(waitForPID(at: leaderFile))
        let descendantPID = try XCTUnwrap(waitForPID(at: descendantFile))
        cancellation.cancel()

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        switch try XCTUnwrap(result.value) {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        case .success(let processResult):
            XCTFail("cancelled process returned status \(processResult.exitCode)")
        }
        XCTAssertFalse(processExists(leaderPID))
        XCTAssertFalse(processExists(descendantPID))
    }

    func testDeadlineTerminatesProcessAndThrowsDeadlineError() throws {
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        let started = ContinuousClock.now

        XCTAssertThrowsError(
            try fastRunner().run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeoutSec: 5,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testTimeoutTerminatesAndReapsEntireDescendantGroup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let descendantFile = directory.appendingPathComponent("descendant.pid")

        let result = try fastRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                trap '' TERM
                printf '%d' "$$" > "$LEADER_FILE"
                (
                  trap '' TERM
                  while :; do /bin/sleep 1; done
                ) &
                printf '%d' "$!" > "$DESCENDANT_FILE"
                while :; do /bin/sleep 1; done
                """,
            ],
            environment: [
                "LEADER_FILE": leaderFile.path,
                "DESCENDANT_FILE": descendantFile.path,
            ],
            timeoutSec: 0.2
        )
        let leaderPID = try XCTUnwrap(readPID(at: leaderFile))
        let descendantPID = try XCTUnwrap(readPID(at: descendantFile))

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, SIGKILL)
        XCTAssertFalse(processExists(leaderPID))
        XCTAssertFalse(processExists(descendantPID))
    }

    func testObservedTerminalResultWinsConcurrentCancellation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaderFile = directory.appendingPathComponent("leader.pid")
        let descendantFile = directory.appendingPathComponent("descendant.pid")
        let cancellation = ToolCallCancellation()
        let result = LockedProcessResult()
        let completed = DispatchGroup()
        let runner = ProcessRunner(
            terminationGraceSec: 0.3,
            forcedTerminationGraceSec: 0.5
        )
        completed.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            result.store(Result {
                try runner.run(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        """
                        printf '%d' "$$" > "$LEADER_FILE"
                        (
                          trap '' TERM
                          while :; do /bin/sleep 1; done
                        ) &
                        printf '%d' "$!" > "$DESCENDANT_FILE"
                        exit 0
                        """,
                    ],
                    environment: [
                        "LEADER_FILE": leaderFile.path,
                        "DESCENDANT_FILE": descendantFile.path,
                    ],
                    timeoutSec: 5,
                    cancellation: cancellation
                )
            })
        }

        let leaderPID = try XCTUnwrap(waitForPID(at: leaderFile))
        let descendantPID = try XCTUnwrap(waitForPID(at: descendantFile))
        XCTAssertTrue(waitForProcessExit(leaderPID, timeout: 1))
        cancellation.cancel()

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        switch try XCTUnwrap(result.value) {
        case .success(let processResult):
            XCTAssertEqual(processResult.exitCode, 0)
            XCTAssertFalse(processResult.timedOut)
        case .failure(let error):
            XCTFail("terminal command lost to cancellation: \(error)")
        }
        XCTAssertFalse(processExists(descendantPID))
    }

    func testMalformedAndCapSplitUTF8PreserveReadableOutput() throws {
        let malformed = try fastRunner().run(
            executable: "/usr/bin/printf",
            arguments: ["valid-prefix\\377suffix"],
            timeoutSec: 1
        )
        XCTAssertEqual(malformed.stdout, "valid-prefix\u{FFFD}suffix")
        XCTAssertFalse(malformed.stdoutTruncated)

        let capSplit = try fastRunner().run(
            executable: "/usr/bin/printf",
            arguments: ["A\\342\\202\\254"],
            timeoutSec: 1,
            maximumOutputBytes: 3
        )
        XCTAssertEqual(capSplit.stdout, "A\u{FFFD}")
        XCTAssertTrue(capSplit.stdoutTruncated)
    }

    func testParallelRunsRemainBoundedAndIndependent() {
        let runner = fastRunner()
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                if index.isMultiple(of: 2) {
                    let result = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
                    if result.exitCode != 0 || result.timedOut {
                        failures.append("normal \(index): \(result.exitCode), timeout=\(result.timedOut)")
                    }
                } else {
                    let result = try runner.run(
                        executable: "/bin/sleep",
                        arguments: ["2"],
                        timeoutSec: 0.02
                    )
                    if !result.timedOut || result.exitCode == 0 {
                        failures.append("timeout \(index): \(result.exitCode), timeout=\(result.timedOut)")
                    }
                }
            } catch {
                failures.append("run \(index) threw \(error)")
            }
        }

        XCTAssertEqual(failures.values, [])
    }

    func testRapidExitNotificationsAreNotLostUnderLoad() {
        let runner = fastRunner()
        let failures = FailureBox()
        let started = ContinuousClock.now

        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                let result = try runner.run(executable: "/usr/bin/true", timeoutSec: 1)
                if result.exitCode != 0 || result.timedOut {
                    failures.append(
                        "rapid \(index): \(result.exitCode), timeout=\(result.timedOut)"
                    )
                }
            } catch {
                failures.append("rapid \(index) threw \(error)")
            }
        }

        XCTAssertEqual(failures.values, [])
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-process-runner-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForPID(at url: URL, timeout: TimeInterval = 1) -> Int32? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if let pid = readPID(at: url) { return pid }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return readPID(at: url)
    }

    private func readPID(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForProcessExit(_ processIdentifier: Int32, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while processExists(processIdentifier), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !processExists(processIdentifier)
    }

    private func processExists(_ processIdentifier: Int32) -> Bool {
        let result = kill(processIdentifier, 0)
        return result == 0 || errno == EPERM
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedProcessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<ProcessResult, Error>?

    var value: Result<ProcessResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ value: Result<ProcessResult, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

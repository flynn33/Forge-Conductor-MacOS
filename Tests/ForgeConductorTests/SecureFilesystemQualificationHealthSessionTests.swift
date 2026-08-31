import Darwin
import Foundation
import XCTest
import ForgeFilesystemProtocol
@testable import ForgeConductorCore

final class SecureFilesystemQualificationHealthSessionTests: XCTestCase {
    private let allowedHash = String(repeating: "a", count: 40)

    func testWrongIdentityTerminatesBeforeStatusDispatch() {
        var machine = SecureFilesystemQualificationHealthStateMachine(
            sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        XCTAssertTrue(machine.beginPreCheck())

        let disposition = machine.receiveServiceInfo(
            serviceInfo(codeDirectoryHash: String(repeating: "b", count: 40)),
            allowedCodeDirectoryHashes: [allowedHash]
        )

        XCTAssertEqual(disposition, .completed)
        XCTAssertEqual(machine.phase, .failed)
        XCTAssertEqual(
            machine.latestSnapshot?.code,
            ForgeFilesystemErrorCode.helperIdentityMismatch
        )
        XCTAssertFalse(machine.latestSnapshot?.serviceIdentityVerified ?? true)
    }

    func testTimeoutIsTerminalAndLateCallbacksCannotOverwriteFailure() {
        var machine = SecureFilesystemQualificationHealthStateMachine(
            sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        XCTAssertTrue(machine.beginPreCheck())
        XCTAssertEqual(
            machine.fail(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem health pre-check timed out"
            ),
            .signalPreCheck
        )
        let timedOutSnapshot = machine.latestSnapshot

        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .ignore
        )
        XCTAssertFalse(machine.receiveStatus(validStatus()))
        XCTAssertEqual(machine.phase, .failed)
        XCTAssertEqual(machine.latestSnapshot, timedOutSnapshot)
    }

    func testPreCheckCompletionWinningDeadlineIsNotReclassifiedAsPostFailure() {
        var machine = SecureFilesystemQualificationHealthStateMachine(
            sessionID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        XCTAssertTrue(machine.beginPreCheck())
        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .requestStatus
        )
        XCTAssertTrue(machine.receiveStatus(validStatus()))
        let completedSnapshot = machine.latestSnapshot

        XCTAssertEqual(machine.timeout(check: .preHealth), .ignore)
        XCTAssertEqual(machine.phase, .readyForPostCheck)
        XCTAssertEqual(machine.latestSnapshot, completedSnapshot)
    }

    func testPreAndPostChecksUseTheSameConnectionAndSession() {
        let fixedSessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let connection = MockHealthConnection(
            serviceInfo: serviceInfo(codeDirectoryHash: allowedHash),
            statuses: [validStatus(), validStatus()]
        )
        var factoryCount = 0
        var receivedRequirement: String?
        let session = SecureFilesystemQualificationHealthSession(
            sessionID: fixedSessionID,
            allowedCodeDirectoryHashes: [allowedHash],
            signingRequirement: "exact sealed daemon requirement",
            connectionFactory: { requirement, _ in
            factoryCount += 1
            receivedRequirement = requirement
            return connection
            }
        )

        let preHealth = session.open(timeout: 0.1)
        let postHealth = session.postCheck(timeout: 0.1)
        session.close()

        XCTAssertTrue(preHealth.ok)
        XCTAssertTrue(postHealth.ok)
        XCTAssertEqual(preHealth.sessionID, postHealth.sessionID)
        XCTAssertEqual(preHealth.sessionID, fixedSessionID.uuidString.lowercased())
        XCTAssertEqual(preHealth.allowedCodeDirectoryHashes, [allowedHash])
        XCTAssertEqual(postHealth.allowedCodeDirectoryHashes, [allowedHash])
        XCTAssertEqual(
            preHealth.jsonObject["allowed_code_directory_hashes"] as? [String],
            [allowedHash]
        )
        XCTAssertFalse(preHealth.connectionReused)
        XCTAssertTrue(postHealth.connectionReused)
        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(receivedRequirement, "exact sealed daemon requirement")
        XCTAssertEqual(connection.activateCount, 1)
        XCTAssertEqual(connection.serviceInfoCallCount, 1)
        XCTAssertEqual(connection.statusCallCount, 2)
        XCTAssertEqual(connection.invalidateCount, 1)
    }

    func testHeldConnectionInterruptionFailsPostCheckWithoutFreshDispatch() {
        let fixedSessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let connection = MockHealthConnection(
            serviceInfo: serviceInfo(codeDirectoryHash: allowedHash),
            statuses: [validStatus(), validStatus()]
        )
        let session = SecureFilesystemQualificationHealthSession(
            sessionID: fixedSessionID,
            allowedCodeDirectoryHashes: [allowedHash],
            connectionFactory: { _, failure in
            connection.failureHandler = failure
            return connection
            }
        )

        let preHealth = session.open(timeout: 0.1)
        connection.interrupt()
        let postHealth = session.postCheck(timeout: 0.1)
        session.close()

        XCTAssertTrue(preHealth.ok)
        XCTAssertFalse(postHealth.ok)
        XCTAssertEqual(postHealth.check, .postHealth)
        XCTAssertEqual(postHealth.sessionID, preHealth.sessionID)
        XCTAssertEqual(
            postHealth.code,
            ForgeFilesystemErrorCode.helperUnavailable
        )
        XCTAssertTrue(postHealth.serviceIdentityVerified)
        XCTAssertTrue(postHealth.connectionReused)
        XCTAssertEqual(connection.statusCallCount, 1)
        XCTAssertEqual(connection.activateCount, 1)
        XCTAssertEqual(connection.invalidateCount, 1)
    }

    func testStatusMustMatchTheReadOnlyHealthContract() {
        var machine = SecureFilesystemQualificationHealthStateMachine(
            sessionID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        XCTAssertTrue(machine.beginPreCheck())
        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash]
            ),
            .requestStatus
        )

        XCTAssertTrue(machine.receiveStatus(ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "Incomplete health response",
            committed: false,
            durabilityConfirmed: false
        )))

        XCTAssertEqual(machine.phase, .failed)
        XCTAssertEqual(
            machine.latestSnapshot?.code,
            "secure_filesystem_health_status_invalid"
        )
        XCTAssertFalse(machine.latestSnapshot?.ok ?? true)
        XCTAssertTrue(machine.latestSnapshot?.serviceIdentityVerified ?? false)
        XCTAssertFalse(machine.latestSnapshot?.statusDurabilityConfirmed ?? true)
    }

    func testCallbacksAtOrAfterAbsoluteDeadlineCannotProduceHealthSuccess() {
        for callbackTime in [UInt64(100), UInt64(101)] {
            var lateIdentity = SecureFilesystemQualificationHealthStateMachine()
            XCTAssertTrue(lateIdentity.beginPreCheck(deadlineNanoseconds: 100))
            XCTAssertEqual(
                lateIdentity.receiveServiceInfo(
                    serviceInfo(codeDirectoryHash: allowedHash),
                    allowedCodeDirectoryHashes: [allowedHash],
                    monotonicTimestampNanoseconds: callbackTime
                ),
                .completed
            )
            XCTAssertFalse(lateIdentity.storedSnapshot(for: .preHealth)?.ok ?? true)
            XCTAssertEqual(
                lateIdentity.storedSnapshot(for: .preHealth)?.code,
                ForgeFilesystemErrorCode.helperUnavailable
            )

            var latePreStatus = SecureFilesystemQualificationHealthStateMachine()
            XCTAssertTrue(latePreStatus.beginPreCheck(deadlineNanoseconds: 100))
            XCTAssertEqual(
                latePreStatus.receiveServiceInfo(
                    serviceInfo(codeDirectoryHash: allowedHash),
                    allowedCodeDirectoryHashes: [allowedHash],
                    monotonicTimestampNanoseconds: 99
                ),
                .requestStatus
            )
            XCTAssertTrue(latePreStatus.receiveStatus(
                validStatus(),
                monotonicTimestampNanoseconds: callbackTime
            ))
            XCTAssertFalse(latePreStatus.storedSnapshot(for: .preHealth)?.ok ?? true)

            var latePostStatus = SecureFilesystemQualificationHealthStateMachine()
            XCTAssertTrue(latePostStatus.beginPreCheck(deadlineNanoseconds: 100))
            XCTAssertEqual(
                latePostStatus.receiveServiceInfo(
                    serviceInfo(codeDirectoryHash: allowedHash),
                    allowedCodeDirectoryHashes: [allowedHash],
                    monotonicTimestampNanoseconds: 1
                ),
                .requestStatus
            )
            XCTAssertTrue(latePostStatus.receiveStatus(
                validStatus(),
                monotonicTimestampNanoseconds: 2
            ))
            XCTAssertTrue(latePostStatus.beginPostCheck(deadlineNanoseconds: 100))
            XCTAssertTrue(latePostStatus.receiveStatus(
                validStatus(),
                monotonicTimestampNanoseconds: callbackTime
            ))
            XCTAssertFalse(latePostStatus.storedSnapshot(for: .postHealth)?.ok ?? true)
        }
    }

    func testPostFailureCannotOverwriteCompletedPreHealthSnapshot() {
        var machine = SecureFilesystemQualificationHealthStateMachine()
        XCTAssertTrue(machine.beginPreCheck(deadlineNanoseconds: 100))
        XCTAssertEqual(
            machine.receiveServiceInfo(
                serviceInfo(codeDirectoryHash: allowedHash),
                allowedCodeDirectoryHashes: [allowedHash],
                monotonicTimestampNanoseconds: 1
            ),
            .requestStatus
        )
        XCTAssertTrue(machine.receiveStatus(
            validStatus(),
            monotonicTimestampNanoseconds: 2
        ))
        XCTAssertEqual(
            machine.fail(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "held connection interrupted"
            ),
            .recordedForPostCheck
        )

        XCTAssertTrue(machine.storedSnapshot(for: .preHealth)?.ok ?? false)
        XCTAssertEqual(machine.storedSnapshot(for: .preHealth)?.check, .preHealth)
        XCTAssertFalse(machine.storedSnapshot(for: .postHealth)?.ok ?? true)
        XCTAssertEqual(machine.storedSnapshot(for: .postHealth)?.check, .postHealth)
    }

    func testInterruptionAfterPreReplyPreservesTwoLineEvidenceContract() {
        let connection = MockHealthConnection(
            serviceInfo: serviceInfo(codeDirectoryHash: allowedHash),
            statuses: [validStatus(), validStatus()]
        )
        connection.interruptAfterStatusCall = 1
        let session = SecureFilesystemQualificationHealthSession(
            allowedCodeDirectoryHashes: [allowedHash],
            connectionFactory: { _, failure in
                connection.failureHandler = failure
                return connection
            }
        )

        let preHealth = session.open(timeout: 0.1)
        let postHealth = session.postCheck(timeout: 0.1)
        session.close()

        XCTAssertEqual(preHealth.check, .preHealth)
        XCTAssertTrue(preHealth.ok)
        XCTAssertEqual(postHealth.check, .postHealth)
        XCTAssertFalse(postHealth.ok)
        XCTAssertEqual(connection.statusCallCount, 1)
    }

    func testPostCheckAfterCloseCannotReturnStaleSuccess() {
        let connection = MockHealthConnection(
            serviceInfo: serviceInfo(codeDirectoryHash: allowedHash),
            statuses: [validStatus(), validStatus()]
        )
        let session = SecureFilesystemQualificationHealthSession(
            allowedCodeDirectoryHashes: [allowedHash],
            connectionFactory: { _, _ in connection }
        )
        XCTAssertTrue(session.open(timeout: 0.1).ok)
        XCTAssertTrue(session.postCheck(timeout: 0.1).ok)
        session.close()

        let afterClose = session.postCheck(timeout: 0.1)
        XCTAssertEqual(afterClose.check, .postHealth)
        XCTAssertFalse(afterClose.ok)
        XCTAssertEqual(afterClose.code, "secure_filesystem_health_invalid_state")
    }

    func testQualificationHealthCommandIsAbsentFromRealCLIHelp() throws {
        let result = try runCLI(arguments: ["help"], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertFalse(result.stdout.contains("qualification-filesystem-health"))
    }

    func testInvalidQualificationHealthArgumentsExitBeforeRealBarrierOrXPC() throws {
        let result = try runCLI(
            arguments: ["qualification-filesystem-health", "--hold-ms", "499"],
            environment: [
                "FORGE_FILESYSTEM_QUALIFICATION_HEALTH_START_SUSPENDED": "1",
            ],
            timeout: 3
        )
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.isEmpty)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        let data = try XCTUnwrap(lines.first?.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "argument_error")
        XCTAssertEqual(object["ok"] as? Bool, false)
    }

    func testRealQualificationHealthBarrierStopsBeforeOutputAndXPC() throws {
        let cli = try builtCLI()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-health-barrier-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: stdoutURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = cli
        process.arguments = ["qualification-filesystem-health", "--hold-ms", "500"]
        var environment = ProcessInfo.processInfo.environment
        environment["FORGE_FILESYSTEM_QUALIFICATION_HEALTH_START_SUSPENDED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        let deadline = Date().addingTimeInterval(3)
        var stopped = false
        while Date() < deadline, process.isRunning {
            let state = try ProcessRunner().run(
                executable: "/bin/ps",
                arguments: ["-o", "state=", "-p", "\(process.processIdentifier)"],
                timeoutSec: 1,
                maximumOutputBytes: 1_024
            )
            if state.exitCode == 0, state.stdout.contains("T") {
                stopped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(stopped, "qualification CLI did not enter its pre-XPC SIGSTOP barrier")
        XCTAssertEqual(try fileSize(stdoutURL), 0)
        XCTAssertEqual(try fileSize(stderrURL), 0)

        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGKILL), 0)
        let terminationDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(process.isRunning, "stopped qualification CLI did not terminate")
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func builtCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let candidate = products.appendingPathComponent("forge-conductor")
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: candidate.path)
                ? candidate
                : nil,
            "The active test products directory does not contain forge-conductor"
        )
    }

    private func runCLI(
        arguments: [String],
        environment additions: [String: String] = [:],
        timeout: TimeInterval
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = try builtCLI()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additions { environment[key] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        guard terminated.wait(timeout: .now() + timeout) == .success else {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 2)
            XCTFail("CLI command exceeded its bounded test deadline: \(arguments)")
            throw NSError(
                domain: "SecureFilesystemQualificationHealthSessionTests",
                code: 1
            )
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self)
        )
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).uint64Value
    }

    private func serviceInfo(codeDirectoryHash: String) -> ForgeFilesystemServiceInfo {
        ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        )
    }

    private func validStatus() -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "Secure filesystem service is available",
            committed: false,
            durabilityConfirmed: true
        )
    }
}

private final class MockHealthConnection: SecureFilesystemQualificationHealthConnection {
    private let serviceInformation: ForgeFilesystemServiceInfo
    private var statuses: [ForgeFilesystemResponse]

    private(set) var activateCount = 0
    private(set) var serviceInfoCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var invalidateCount = 0
    var failureHandler: ((String, String) -> Void)?
    var interruptAfterStatusCall: Int?

    init(
        serviceInfo: ForgeFilesystemServiceInfo,
        statuses: [ForgeFilesystemResponse]
    ) {
        self.serviceInformation = serviceInfo
        self.statuses = statuses
    }

    func activate() {
        activateCount += 1
    }

    func requestServiceInfo(_ reply: @escaping (ForgeFilesystemServiceInfo) -> Void) {
        serviceInfoCallCount += 1
        reply(serviceInformation)
    }

    func requestStatus(_ reply: @escaping (ForgeFilesystemResponse) -> Void) {
        statusCallCount += 1
        guard !statuses.isEmpty else { return }
        reply(statuses.removeFirst())
        if interruptAfterStatusCall == statusCallCount {
            interrupt()
        }
    }

    func invalidate() {
        invalidateCount += 1
    }

    func interrupt() {
        failureHandler?(
            ForgeFilesystemErrorCode.helperUnavailable,
            "Secure filesystem health connection was interrupted"
        )
    }
}

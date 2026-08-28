// RuntimeExecutionJobTests.swift
// Focused lifecycle, output-bound, capability, and generation-fence proof for durable jobs.

import Darwin
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class RuntimeExecutionJobTests: XCTestCase {
    private actor InitializationGate {
        private let participantCount: Int
        private var arrivalCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(participantCount: Int) {
            self.participantCount = participantCount
        }

        func wait() async {
            arrivalCount += 1
            if arrivalCount == participantCount {
                let pending = waiters
                waiters.removeAll(keepingCapacity: false)
                for waiter in pending { waiter.resume() }
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private actor PostCancellationCommitGate {
        private var paused = false
        private var released = false
        private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            paused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { continuation in
                pauseWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private final class RepositoryCommitGate: @unchecked Sendable {
        private let expectedKind: RuntimeJobCommitKind
        private let committed = DispatchSemaphore(value: 0)
        private let releaseCommit = DispatchSemaphore(value: 0)

        init(expectedKind: RuntimeJobCommitKind) {
            self.expectedKind = expectedKind
        }

        func observe(_ kind: RuntimeJobCommitKind) {
            guard kind == expectedKind else { return }
            committed.signal()
            _ = releaseCommit.wait(timeout: .now() + 2)
        }

        func waitUntilCommitted(timeout: TimeInterval = 1) -> DispatchTimeoutResult {
            committed.wait(timeout: .now() + timeout)
        }

        func release() {
            releaseCommit.signal()
        }
    }

    func testConcurrentStdoutAndStderrDrainWithoutDeadlockAndSpillWithinBudget() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let script = """
        i=0
        while [ "$i" -lt 3000 ]; do
          printf 'stdout-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' "$i"
          printf 'stderr-%04d-ABCDEFGHIJKLMNOPQRSTUVWXYZ9876543210\\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let jobID = try await fixture.service.submit(
            fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 10)
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(15)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertNotNil(record.outputArtifactID)

        let stdout = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        let stderr = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stderr,
            context: fixture.context
        )
        XCTAssertGreaterThan(stdout.byteCount, stdout.retainedByteCount)
        XCTAssertGreaterThan(stderr.byteCount, stderr.retainedByteCount)
        XCTAssertTrue(stdout.inlineTruncated)
        XCTAssertTrue(stderr.inlineTruncated)
        XCTAssertTrue(stdout.artifactTruncated)
        XCTAssertTrue(stderr.artifactTruncated)
        XCTAssertLessThanOrEqual(
            stdout.retainedByteCount + stderr.retainedByteCount,
            UInt64(fixture.limits.maximumArtifactBytesPerJob)
        )
        XCTAssertLessThanOrEqual(
            stdout.inlineText.utf8.count + stderr.inlineText.utf8.count,
            fixture.limits.maximumInlineOutputBytes
        )

        let slice = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 4096,
            context: fixture.context
        )
        XCTAssertEqual(slice.data.count, 4096)
        XCTAssertFalse(slice.eof)
        XCTAssertTrue(slice.artifactTruncated)
        await fixture.close()
    }

    func testTimeoutTerminatesDescendantProcessGroup() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("timeout-descendant.pid")
        let script = """
        (
          trap '' TERM
          while :; do sleep 1; done
        ) &
        echo $! > timeout-descendant.pid
        wait
        """
        let jobID = try await fixture.service.submit(
            fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 5)
        )
        guard await Self.waitForFile(pidFile) else {
            XCTFail("timed runtime fixture did not start its descendant")
            await fixture.close()
            return
        }
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(12)
        )
        XCTAssertEqual(record.state, .timedOut)
        let descendant = try Self.readPID(pidFile)
        let descendantGone = await Self.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(descendantGone)
        await fixture.close()
    }

    func testCancellationTerminatesDescendantProcessGroup() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("cancel-descendant.pid")
        let script = """
        (
          trap '' TERM
          while :; do sleep 1; done
        ) &
        echo $! > cancel-descendant.pid
        wait
        """
        let jobID = try await fixture.service.submit(
            fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 30)
        )
        let pidFileReady = await Self.waitForFile(pidFile)
        XCTAssertTrue(pidFileReady)
        let persistedIdentity = try await fixture.runtimeRepository.recoveryProcessIdentity(
            jobID: jobID
        )
        XCTAssertNotNil(persistedIdentity)
        XCTAssertEqual(
            persistedIdentity?.processIdentifier,
            persistedIdentity?.processGroupIdentifier
        )
        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .cancelled)
        let descendant = try Self.readPID(pidFile)
        let descendantGone = await Self.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(descendantGone)
        await fixture.close()
    }

    func testLegacyShellAdapterTaskCancellationTerminatesDescendantProcessGroup() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("legacy-cancel-descendant.pid")
        let adapter = LegacyShellJobAdapter(service: fixture.service)
        let task = Task {
            try await adapter.execute(
                command: """
                (
                  trap '' TERM
                  while :; do sleep 1; done
                ) &
                echo $! > legacy-cancel-descendant.pid
                wait
                """,
                workingDirectory: fixture.projectRoot,
                timeoutSeconds: 30,
                context: fixture.context
            )
        }

        let pidFileReady = await Self.waitForFile(pidFile)
        XCTAssertTrue(pidFileReady)
        let descendant = try Self.readPID(pidFile)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled legacy shell task returned a result")
        } catch is CancellationError {
            // Expected: connector cancellation remains cancellation at the compatibility edge.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        let jobs = try await fixture.service.list(context: fixture.context)
        let job = try XCTUnwrap(jobs.first { $0.executionProfile == .legacyBashLogin })
        let record = try await fixture.service.waitForTerminal(
            jobID: job.jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .cancelled)
        let descendantGone = await Self.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(descendantGone)
        await fixture.close()
    }

    func testForkTreeExceedingPerJobDescendantBudgetIsTerminated() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 512,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 50,
            forcedTerminationGraceMilliseconds: 500,
            maximumDescendantProcessesPerJob: 2
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("fork-tree.pids")
        let script = """
        : > fork-tree.pids
        i=0
        while [ "$i" -lt 8 ]; do
          sleep 30 &
          echo $! >> fork-tree.pids
          i=$((i + 1))
        done
        wait
        """
        let jobID = try await fixture.service.submit(
            fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 20)
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.errorCode, "runtime_descendant_limit_exceeded")
        let pids = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        XCTAssertGreaterThan(pids.count, limits.maximumDescendantProcessesPerJob)
        for pid in pids {
            let descendantGone = await Self.waitUntilProcessIsGone(pid)
            XCTAssertTrue(descendantGone, "descendant \(pid) survived")
        }
        await fixture.close()
    }

    func testLiveTerminationFailurePersistsAndReaperEventuallyCompletes() async throws {
        let controller = SwitchableRecoveredProcessController(failing: true)
        let fixture = try await Fixture.make(recoveredProcessController: controller)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "trap '' TERM; while :; do sleep 1; done",
                timeout: 30
            )
        )
        let reachedRunning = await fixture.waitForState(jobID, expected: .running)
        XCTAssertTrue(reachedRunning)
        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let recoveryObserved = await Self.waitUntil {
            await fixture.service.recoveryPendingJobIDs().contains(jobID)
        }
        XCTAssertTrue(recoveryObserved)
        let durable = try await fixture.runtimeRepository.terminationRecord(jobID: jobID)
        XCTAssertNotNil(durable?.probeDeadline)
        XCTAssertNotEqual(durable?.phase, .confirmed)

        await controller.setFailing(false)
        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .cancelled)
        let recoveryPending = await fixture.service.recoveryPendingJobIDs()
        XCTAssertTrue(recoveryPending.isEmpty)
        await fixture.close()
    }

    func testShutdownReportsOwnedProcessUntilPersistedReaperConfirmsDeath() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 256,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 20,
            forcedTerminationGraceMilliseconds: 20
        )
        let controller = SwitchableRecoveredProcessController(failing: true)
        let fixture = try await Fixture.make(
            limits: limits,
            recoveredProcessController: controller
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "trap '' TERM; while :; do sleep 1; done",
                timeout: 30
            )
        )
        let reachedRunning = await fixture.waitForState(jobID, expected: .running)
        XCTAssertTrue(reachedRunning)
        let firstReport = await fixture.service.shutdown()
        XCTAssertFalse(firstReport.completed)
        XCTAssertTrue(firstReport.unresolvedJobIDs.contains(jobID))
        let cancelling = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(cancelling?.state, .cancelling)

        await controller.setFailing(false)
        let secondReport = await fixture.service.shutdown()
        XCTAssertTrue(secondReport.completed)
        XCTAssertTrue(secondReport.unresolvedJobIDs.isEmpty)
        let cancelled = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(cancelled?.state, .cancelled)
        await fixture.runtimeRepository.close()
        await fixture.controlRepository.close()
    }

    func testLauncherAppliesPerProcessCPUFileDescriptorFileSizeAndCoreLimits() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 512,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 50,
            forcedTerminationGraceMilliseconds: 500,
            maximumCPUSecondsPerProcess: 20,
            maximumOpenFilesPerProcess: 64,
            maximumFileBytesPerProcess: 1_048_576,
            maximumCoreBytesPerProcess: 0
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf 'cpu=%s fd=%s file=%s core=%s' \"$(ulimit -t)\" \"$(ulimit -n)\" \"$(ulimit -f)\" \"$(ulimit -c)\"",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let output = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        XCTAssertEqual(output.inlineText, "cpu=7 fd=64 file=1024 core=0")
        await fixture.close()
    }

    func testCancellationAfterIdentityCommitButBeforeGateReleaseNeverExecutesRequest() async throws {
        let gate = LaunchGate()
        let fixture = try await Fixture.make(launchObserver: gate)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("launch-race-descendant.pid")
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "(trap '' TERM; while :; do sleep 1; done) & echo $! > launch-race-descendant.pid; wait",
                timeout: 30
            )
        )
        await gate.waitForSpawn()
        let persistedIdentity = try await fixture.runtimeRepository.recoveryProcessIdentity(
            jobID: jobID
        )
        XCTAssertNotNil(persistedIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        do {
            try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        let recoveryPending = await fixture.service.recoveryPendingJobIDs()
        XCTAssertTrue(recoveryPending.isEmpty)
        await fixture.close()
    }

    func testLaunchGatePersistsExactIdentityBeforeRequestExecution() async throws {
        let gate = LaunchGate()
        let fixture = try await Fixture.make(launchObserver: gate)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.projectRoot.appendingPathComponent("launch-gate-marker")
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf committed > launch-gate-marker",
                timeout: 5
            )
        )

        await gate.waitForSpawn()
        let recoveredIdentity = try await fixture.runtimeRepository.recoveryProcessIdentity(
            jobID: jobID
        )
        let persistedIdentity = try XCTUnwrap(recoveredIdentity)
        XCTAssertEqual(
            persistedIdentity.processIdentifier,
            persistedIdentity.processGroupIdentifier
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        await gate.release()
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "committed")
        await fixture.close()
    }

    func testZshNoProfileDisablesRCSOption() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .shell,
                profile: .zshNoProfile,
                script: "if [[ -o rcs ]]; then exit 42; fi; print -r -- zsh-no-rcs",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let diagnostic = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stderr,
            offset: 0,
            limit: 4_096,
            context: fixture.context
        )
        let diagnosticText = String(decoding: diagnostic.data, as: UTF8.self)
        XCTAssertEqual(record.state, .completed, diagnosticText)
        XCTAssertEqual(record.exitCode, 0, diagnosticText)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "zsh-no-rcs\n")
        await fixture.close()
    }

    func testBashNoProfileIsNonLoginAndIgnoresInheritedBASHEnvironment() async throws {
        let environmentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-bash-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: environmentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: environmentRoot) }
        let inheritedScript = environmentRoot.appendingPathComponent("inherited-bash-env.sh")
        try "exit 97\n".write(to: inheritedScript, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["BASH_ENV"] = inheritedScript.path

        let fixture = try await Fixture.make(environment: environment)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: """
                shopt -q login_shell && exit 91
                case "$-" in *i*) exit 92 ;; esac
                printf 'bash-clean'
                """,
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let diagnostic = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stderr,
            offset: 0,
            limit: 2_048,
            context: fixture.context
        )
        let diagnosticText = String(decoding: diagnostic.data, as: UTF8.self)
        XCTAssertEqual(record.executionProfile, .bashNoProfile)
        XCTAssertEqual(record.state, .completed, diagnosticText)
        XCTAssertEqual(record.exitCode, 0)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "bash-clean")
        await fixture.close()
    }

    func testDirectProcessUsesArgumentVectorWithoutShellParsing() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = RuntimeJobRequest(
            kind: .process,
            profile: .directProcess,
            context: fixture.context,
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "literal;$(exit 99)"],
            canonicalWorkingDirectory: fixture.projectRoot,
            timeout: .seconds(5),
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
            replayClass: .readOnly
        )
        let jobID = try await fixture.service.submit(request)
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "literal;$(exit 99)")
        await fixture.close()
    }

    func testNonUTF8OutputRetainsRawBytesWithConsistentCountAndReadback() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf '\\377\\376A'",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let metadata = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        XCTAssertEqual(metadata.byteCount, 3)
        XCTAssertEqual(metadata.retainedByteCount, 3)
        XCTAssertNotNil(metadata.artifactRelativePath)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1024,
            context: fixture.context
        )
        XCTAssertEqual(output.data, Data([0xff, 0xfe, 0x41]))
        XCTAssertEqual(output.nextOffset, 3)
        XCTAssertEqual(output.totalRetainedBytes, 3)
        XCTAssertTrue(output.eof)
        XCTAssertEqual(output.sha256, metadata.sha256)
        await fixture.close()
    }

    func testChildCanReadAuthorizedRootButCannotWriteWhenWritableRootsAreEmpty() async throws {
        let fixture = try await Fixture.make(readOnlyProject: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let input = fixture.projectRoot.appendingPathComponent("read-only-input")
        let deniedOutput = fixture.projectRoot.appendingPathComponent("must-not-write")
        try Data("read-visible".utf8).write(to: input, options: .atomic)

        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "cat read-only-input; printf denied > must-not-write",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedOutput.path))
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "read-visible")
        await fixture.close()
    }

    func testControlPlaneRejectsWritableRootOutsideReadAuthorization() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-writable", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [fixture.projectRoot],
            writableRoots: [outside],
            allowedTools: ["shell.run"],
            networkAllowed: false,
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes
        )
        do {
            _ = try await fixture.controlRepository.bind(
                owner: ProjectBindingOwner(kind: .mcpClient, id: "invalid-writable-client"),
                projectID: fixture.projectID,
                generation: fixture.context.projectGeneration,
                authorizationScope: scope
            )
            XCTFail("writable root outside the read scope unexpectedly persisted")
        } catch let error as ProjectContextError {
            XCTAssertEqual(error.code, "invalid_authorization_scope")
        }
        await fixture.close()
    }

    func testLegacyAuthorizationJSONDefaultsWritableRootsToReadRoots() throws {
        let root = URL(fileURLWithPath: "/tmp/forge-legacy-authorization")
        let legacy: [String: Any] = [
            "canonicalRoots": [root.absoluteString],
            "allowedTools": ["shell.run"],
            "networkAllowed": false,
            "maximumInlineOutputBytes": 1_024,
        ]
        let decoded = try JSONDecoder().decode(
            ToolAuthorizationScope.self,
            from: JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        )
        XCTAssertEqual(decoded.canonicalRoots, [root])
        XCTAssertEqual(decoded.writableRoots, [root])
    }

    func testChildCannotUnlinkOrReplaceManagerOwnedOutputFiles() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = """
        output_directory=${0%/*}
        if rm -f "$output_directory/stdout.log"; then exit 91; fi
        if printf replaced > "$output_directory/stdout.log"; then exit 92; fi
        printf 'manager-owned-output'
        """
        let jobID = try await fixture.service.submit(
            fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 5)
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "manager-owned-output")
        await fixture.close()
    }

    func testTerminalPersistenceFailureRetainsOwnershipAndLeavesRecoverableDurableState() async throws {
        let gate = LaunchGate()
        let fixture = try await Fixture.make(launchObserver: gate)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 0.1",
                timeout: 5
            )
        )
        await gate.waitForSpawn()
        await fixture.runtimeRepository.close()
        await gate.release()

        var recoveryPending: [UUID] = []
        for _ in 0..<200 {
            recoveryPending = await fixture.service.recoveryPendingJobIDs()
            if recoveryPending.contains(jobID) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(recoveryPending.contains(jobID))

        let reopened = try RuntimeJobRepository(
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite")
        )
        let durable = try await reopened.job(jobID)
        XCTAssertEqual(durable?.state, .running)
        XCTAssertFalse(durable?.state.isTerminal ?? true)
        await reopened.close()
        await fixture.close()
    }

    func testTransientTerminalPersistenceFailureRecoversInProcessAndReleasesConcurrencySlot() async throws {
        let persistenceGate = TerminalPersistenceGate()
        let recoveryLimits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 256,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 100,
            forcedTerminationGraceMilliseconds: 1_000
        )
        let fixture = try await Fixture.make(
            limits: recoveryLimits,
            terminalPersistenceHook: persistenceGate
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf 'recoverable-terminal'",
                timeout: 5
            )
        )

        var recoveryPending = false
        for _ in 0..<200 {
            if await fixture.service.recoveryPendingJobIDs().contains(jobID) {
                recoveryPending = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(recoveryPending)
        let durableBeforeRecovery = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(durableBeforeRecovery?.state, .running)

        await persistenceGate.allowPersistence()
        let recovered = try await fixture.service.status(jobID: jobID, context: fixture.context)
        XCTAssertEqual(recovered.state, .completed)
        let pendingAfterRecovery = await fixture.service.recoveryPendingJobIDs()
        XCTAssertFalse(pendingAfterRecovery.contains(jobID))

        let nextJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf 'next-job'",
                timeout: 5
            )
        )
        let next = try await fixture.service.waitForTerminal(
            jobID: nextJobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(next.state, .completed)
        await fixture.close()
    }

    func testSchemaV2MigratesForwardWithProcessIdentityAndIdempotencyReceiptStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-v2-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("runtime-v2.sqlite")
        let legacyJobID = UUID()
        let legacyProjectID = ProjectID()
        try Self.createRuntimeSchemaV2(
            at: databaseURL,
            jobID: legacyJobID,
            projectID: legacyProjectID
        )

        func assertLegacyJob(in repository: RuntimeJobRepository) async throws {
            let storedJob = try await repository.job(legacyJobID)
            let job = try XCTUnwrap(storedJob)
            XCTAssertEqual(job.projectID, legacyProjectID)
            XCTAssertEqual(job.projectGeneration, .initial)
            XCTAssertEqual(job.runtimeKind, .bash)
            XCTAssertEqual(job.executionProfile, .bashNoProfile)
            XCTAssertEqual(job.replayClass, .readOnly)
            XCTAssertEqual(job.state, .completed)
            XCTAssertEqual(job.canonicalWorkingDirectory.path, "/legacy/runtime-project")
            XCTAssertEqual(job.commandSummary, "legacy v2 completed job")
            XCTAssertEqual(job.timeoutSeconds, 30)
            XCTAssertEqual(job.exitCode, 0)
            XCTAssertEqual(job.outputBytes, 14)
            XCTAssertEqual(job.createdAt, "2026-08-26T00:00:00.000Z")
            XCTAssertEqual(job.completedAt, "2026-08-26T00:00:01.000Z")
        }

        let repository = try RuntimeJobRepository(databaseURL: databaseURL)
        let health = try await repository.health()
        XCTAssertEqual(health.schemaVersion, RuntimeJobRepository.schemaVersion)
        XCTAssertEqual(health.integrity.lowercased(), "ok")
        try await assertLegacyJob(in: repository)
        await repository.close()

        let backupURL = root.appendingPathComponent("runtime-v2.pre-migration-v2.sqlite3")
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
            ),
            2
        )
        XCTAssertEqual(try Self.sqliteText(databaseURL: backupURL, sql: "PRAGMA quick_check"), "ok")
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                textBinding: legacyJobID.uuidString.lowercased()
            ),
            1
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )
        let migrationManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(migrationManifest.state, .completed)
        XCTAssertEqual(migrationManifest.storageKind, .sqlite)
        XCTAssertEqual(migrationManifest.sourceVersion, 2)
        XCTAssertEqual(migrationManifest.targetVersion, RuntimeJobRepository.schemaVersion)
        XCTAssertEqual(
            migrationManifest.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertNotNil(migrationManifest.targetSHA256)
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id=?",
                textBinding: migrationManifest.migrationID
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: RuntimeJobRepository.schemaVersion
                ).path
            )
        )
        let firstBackupData = try Data(contentsOf: backupURL)

        let columns = try Self.sqliteColumnNames(
            databaseURL: databaseURL,
            table: "execution_jobs"
        )
        XCTAssertTrue(columns.contains("process_start_seconds"))
        XCTAssertTrue(columns.contains("process_start_microseconds"))
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runtime_job_idempotency_receipts'"
            ),
            1
        )

        let reopened = try RuntimeJobRepository(databaseURL: databaseURL)
        try await assertLegacyJob(in: reopened)
        let reopenedHealth = try await reopened.health()
        XCTAssertEqual(reopenedHealth.schemaVersion, RuntimeJobRepository.schemaVersion)
        await reopened.close()

        let rerun = try RuntimeJobRepository(databaseURL: databaseURL)
        try await assertLegacyJob(in: rerun)
        let rerunHealth = try await rerun.health()
        XCTAssertEqual(rerunHealth.integrity.lowercased(), "ok")
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_schema_version WHERE singleton=1 AND version=\(RuntimeJobRepository.schemaVersion)"
            ),
            1
        )
        await rerun.close()
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)

        try firstBackupData.write(to: databaseURL, options: .atomic)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        let restored = try RuntimeJobRepository(databaseURL: databaseURL)
        try await assertLegacyJob(in: restored)
        await restored.close()
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(
                    contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
                )
            ),
            migrationManifest
        )
    }

    func testRuntimeColumnProbePropagatesStepFailures() throws {
        for stepCode in [SQLITE_BUSY, SQLITE_IOERR] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "forge-runtime-column-probe-\(stepCode)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("runtime.sqlite")

            XCTAssertThrowsError(
                try RuntimeJobRepository(
                    databaseURL: databaseURL,
                    beforeMigrationCommitObserver: nil,
                    tableInfoStepObserver: { stepCode }
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("table-info step failed with code \(stepCode)"),
                    "unexpected error: \(error)"
                )
            }
        }
    }

    func testRuntimeVersionTwoMigrationRejectsStablePathReplacementBeforeCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-runtime-v2-path-replacement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("runtime-v2.sqlite")
        let replacementURL = root.appendingPathComponent("replacement.sqlite")
        let displacedURL = root.appendingPathComponent("displaced.sqlite")
        let backupURL = root.appendingPathComponent("runtime-v2.pre-migration-v2.sqlite3")
        let originalJobID = UUID()
        let replacementJobID = UUID()
        let originalProjectID = ProjectID()
        let replacementProjectID = ProjectID()
        try Self.createRuntimeSchemaV2(
            at: databaseURL,
            jobID: originalJobID,
            projectID: originalProjectID
        )
        try Self.createRuntimeSchemaV2(
            at: replacementURL,
            jobID: replacementJobID,
            projectID: replacementProjectID
        )

        XCTAssertThrowsError(
            try RuntimeJobRepository(
                databaseURL: databaseURL,
                beforeMigrationCommitObserver: {
                    try FileManager.default.moveItem(at: databaseURL, to: displacedURL)
                    try FileManager.default.moveItem(at: replacementURL, to: databaseURL)
                }
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved")
                    || error.localizedDescription.contains("replaced")
                    || error.localizedDescription.contains("movement check"),
                "unexpected error: \(error)"
            )
        }

        try FileManager.default.moveItem(at: databaseURL, to: replacementURL)
        try FileManager.default.moveItem(at: displacedURL, to: databaseURL)

        for fixture in [
            (databaseURL, originalJobID, originalProjectID, replacementJobID),
            (replacementURL, replacementJobID, replacementProjectID, originalJobID),
        ] {
            XCTAssertEqual(
                try Self.sqliteCount(
                    databaseURL: fixture.0,
                    sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
                ),
                2
            )
            XCTAssertEqual(
                try Self.sqliteCount(databaseURL: fixture.0, sql: "SELECT COUNT(*) FROM execution_jobs"),
                1
            )
            XCTAssertEqual(
                try Self.sqliteCount(
                    databaseURL: fixture.0,
                    sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=? AND project_id=?",
                    textBindings: [
                        fixture.1.uuidString.lowercased(),
                        fixture.2.description,
                    ]
                ),
                1
            )
            XCTAssertEqual(
                try Self.sqliteText(
                    databaseURL: fixture.0,
                    sql: "SELECT job_id FROM execution_jobs LIMIT 1"
                ),
                fixture.1.uuidString.lowercased()
            )
            XCTAssertEqual(
                try Self.sqliteText(
                    databaseURL: fixture.0,
                    sql: "SELECT project_id FROM execution_jobs LIMIT 1"
                ),
                fixture.2.description
            )
            XCTAssertEqual(
                try Self.sqliteText(
                    databaseURL: fixture.0,
                    sql: "SELECT command_summary FROM execution_jobs LIMIT 1"
                ),
                "legacy v2 completed job"
            )
            XCTAssertEqual(
                try Self.sqliteText(
                    databaseURL: fixture.0,
                    sql: "SELECT stdout_inline FROM execution_jobs LIMIT 1"
                ),
                "legacy output"
            )
            XCTAssertEqual(
                try Self.sqliteCount(
                    databaseURL: fixture.0,
                    sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                    textBinding: fixture.3.uuidString.lowercased()
                ),
                0
            )
            XCTAssertFalse(
                try Self.sqliteColumnNames(
                    databaseURL: fixture.0,
                    table: "execution_jobs"
                ).contains("process_start_seconds")
            )
            XCTAssertEqual(
                try Self.sqliteCount(
                    databaseURL: fixture.0,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='forge_migration_receipts'"
                ),
                0
            )
        }

        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
            ),
            2
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=? AND project_id=?",
                textBindings: [
                    originalJobID.uuidString.lowercased(),
                    originalProjectID.description,
                ]
            ),
            1
        )
        let activeManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(activeManifest.state, .prepared)
        XCTAssertEqual(activeManifest.sourceVersion, 2)
        XCTAssertEqual(activeManifest.targetVersion, RuntimeJobRepository.schemaVersion)
        XCTAssertEqual(activeManifest.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            activeManifest.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: RuntimeJobRepository.schemaVersion
                ).path
            )
        )
    }

    func testNonemptyUnversionedRuntimeDatabaseFailsClosedWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-unversioned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("runtime.sqlite")
        try Self.createUnversionedRuntimeFixture(at: databaseURL)
        let originalBytes = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(try RuntimeJobRepository(databaseURL: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))

        let freshURL = root.appendingPathComponent("fresh-runtime.sqlite")
        let fresh = try RuntimeJobRepository(databaseURL: freshURL)
        let health = try await fresh.health()
        XCTAssertEqual(health.schemaVersion, RuntimeJobRepository.schemaVersion)
        await fresh.close()
    }

    func testMalformedCoResidentControlPlaneVersionFailsClosedWithoutMutatingWALFamily() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-malformed-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        await controlPlane.close()

        let database = try Self.openSQLiteFixture(at: databaseURL)
        defer { sqlite3_close(database) }
        try Self.executeSQLiteFixture(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            BEGIN IMMEDIATE;
            ALTER TABLE control_schema_version RENAME TO valid_control_schema_version;
            CREATE TABLE control_schema_version(
                singleton INTEGER NOT NULL,
                version INTEGER NOT NULL,
                applied_at TEXT NOT NULL
            );
            INSERT INTO control_schema_version(singleton,version,applied_at)
            VALUES(1,2,'2026-08-27T00:00:00.000Z'),(2,2,'2026-08-27T00:00:00.000Z');
            DROP TABLE valid_control_schema_version;
            COMMIT;
            """,
            database: database
        )
        let before = try Self.sqliteFamilySnapshot(at: databaseURL)
        XCTAssertNotNil(before.writeAheadLog)
        XCTAssertNotNil(before.sharedMemory)

        XCTAssertThrowsError(try RuntimeJobRepository(databaseURL: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Self.sqliteFamilySnapshot(at: databaseURL), before)
    }

    func testColumnTruncatedCoResidentControlPlaneFailsClosedWithoutMutatingWALFamily() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-truncated-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        await controlPlane.close()

        let database = try Self.openSQLiteFixture(at: databaseURL)
        defer { sqlite3_close(database) }
        try Self.executeSQLiteFixture(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            ALTER TABLE migration_receipts RENAME TO complete_migration_receipts;
            CREATE TABLE migration_receipts(
                receipt_id TEXT PRIMARY KEY,
                migration_name TEXT NOT NULL,
                source_version TEXT NOT NULL,
                target_version TEXT NOT NULL,
                source_sha256 TEXT,
                backup_path TEXT,
                backup_sha256 TEXT,
                imported_count INTEGER NOT NULL DEFAULT 0,
                skipped_count INTEGER NOT NULL DEFAULT 0,
                quarantined_count INTEGER NOT NULL DEFAULT 0,
                integrity_result TEXT NOT NULL,
                details_json TEXT NOT NULL DEFAULT '{}',
                started_at TEXT NOT NULL
            );
            DROP TABLE complete_migration_receipts;
            """,
            database: database
        )
        let before = try Self.sqliteFamilySnapshot(at: databaseURL)
        XCTAssertNotNil(before.writeAheadLog)
        XCTAssertNotNil(before.sharedMemory)

        XCTAssertThrowsError(try RuntimeJobRepository(databaseURL: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Self.sqliteFamilySnapshot(at: databaseURL), before)
    }

    func testPostOpenValidationRejectsRegisteredTruncatedControlPlaneWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-post-open-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        await controlPlane.close()

        let database = try Self.openSQLiteFixture(at: databaseURL)
        try Self.executeSQLiteFixture(
            """
            PRAGMA journal_mode=DELETE;
            DROP TABLE provider_turns;
            """,
            database: database
        )
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        let registration = try VerifiedMigrationBackup.registerOpenDatabase(at: databaseURL)
        defer { VerifiedMigrationBackup.unregisterOpenDatabase(registration) }
        let before = try Self.sqliteFamilySnapshot(at: databaseURL)

        XCTAssertThrowsError(try RuntimeJobRepository(databaseURL: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Self.sqliteFamilySnapshot(at: databaseURL), before)
    }

    func testConcurrentInitializersSerializeVersionTwoMigration() async throws {
        let participantCount = 8
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "forge-runtime-v2-concurrent-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("runtime-v2.sqlite")
        let legacyJobID = UUID()
        let legacyProjectID = ProjectID()
        try Self.createRuntimeSchemaV2(
            at: databaseURL,
            jobID: legacyJobID,
            projectID: legacyProjectID
        )

        let gate = InitializationGate(participantCount: participantCount)
        let repositories = try await withThrowingTaskGroup(
            of: RuntimeJobRepository.self,
            returning: [RuntimeJobRepository].self
        ) { group in
            for _ in 0..<participantCount {
                group.addTask {
                    await gate.wait()
                    return try RuntimeJobRepository(databaseURL: databaseURL)
                }
            }
            var opened: [RuntimeJobRepository] = []
            opened.reserveCapacity(participantCount)
            for try await repository in group { opened.append(repository) }
            return opened
        }

        XCTAssertEqual(repositories.count, participantCount)
        for repository in repositories {
            let health = try await repository.health()
            XCTAssertEqual(health.schemaVersion, RuntimeJobRepository.schemaVersion)
            XCTAssertEqual(health.integrity.lowercased(), "ok")
            let storedJob = try await repository.job(legacyJobID)
            let job = try XCTUnwrap(storedJob)
            XCTAssertEqual(job.projectID, legacyProjectID)
            XCTAssertEqual(job.commandSummary, "legacy v2 completed job")
        }
        for repository in repositories { await repository.close() }

        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
            ),
            RuntimeJobRepository.schemaVersion
        )
        let backupURL = root.appendingPathComponent("runtime-v2.pre-migration-v2.sqlite3")
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
            ),
            2
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                textBinding: legacyJobID.uuidString.lowercased()
            ),
            1
        )
        XCTAssertEqual(try Self.sqliteText(databaseURL: backupURL, sql: "PRAGMA quick_check"), "ok")
    }

    func testRegisteredRuntimeVersionTwoMigrationStillCreatesRecoveryManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-runtime-v2-registered-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let legacyJobID = UUID()
        try Self.createRuntimeSchemaV2(
            at: databaseURL,
            jobID: legacyJobID,
            projectID: ProjectID()
        )
        let registration = try VerifiedMigrationBackup.registerOpenDatabase(at: databaseURL)
        defer { VerifiedMigrationBackup.unregisterOpenDatabase(registration) }

        let repository = try RuntimeJobRepository(databaseURL: databaseURL)
        let health = try await repository.health()
        XCTAssertEqual(
            health.schemaVersion,
            RuntimeJobRepository.schemaVersion
        )
        let migratedJob = try await repository.job(legacyJobID)
        XCTAssertNotNil(migratedJob)
        await repository.close()

        let backupURL = root.appendingPathComponent(
            "control-plane.pre-migration-v2.sqlite3"
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
            ),
            2
        )
        let manifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.sourceVersion, 2)
        XCTAssertEqual(manifest.targetVersion, RuntimeJobRepository.schemaVersion)
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id=?",
                textBinding: manifest.migrationID
            ),
            1
        )
    }

    func testCoResidentControlPlaneRuntimeBootstrapCreatesVersionZeroRecoveryManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-runtime-control-plane-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let controlPlane = try ProjectControlPlaneRepository(databaseURL: databaseURL)

        let runtime = try RuntimeJobRepository(databaseURL: databaseURL)
        let health = try await runtime.health()
        XCTAssertEqual(health.schemaVersion, RuntimeJobRepository.schemaVersion)
        await runtime.close()

        let backupURL = root.appendingPathComponent(
            "control-plane.pre-migration-v0.sqlite3"
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT version FROM control_schema_version WHERE singleton=1"
            ),
            ProjectControlPlaneRepository.schemaVersion
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: backupURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runtime_job_schema_version'"
            ),
            0
        )
        let manifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.sourceVersion, 0)
        XCTAssertEqual(manifest.targetVersion, RuntimeJobRepository.schemaVersion)
        XCTAssertEqual(manifest.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id=?",
                textBinding: manifest.migrationID
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: RuntimeJobRepository.schemaVersion
                ).path
            )
        )
        await controlPlane.close()
    }

    func testTerminalLedgerCompactionRetainsBoundedIdempotencyReceiptAndPreventsReplay() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let request = fixture.request(
            kind: .bash,
            profile: .bashNoProfile,
            script: "printf 'idempotent-oldest'",
            timeout: 5,
            replayClass: .idempotent,
            idempotencyKey: "runtime-ledger-stable-key"
        )
        let originalJobID = try await fixture.service.submit(request)
        _ = try await fixture.service.waitForTerminal(
            jobID: originalJobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let newestJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf 'newest-audit-row'",
                timeout: 5
            )
        )
        _ = try await fixture.service.waitForTerminal(
            jobID: newestJobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )

        let compacted = try await fixture.runtimeRepository.compactTerminalJobs(
            maximumPerProject: 100,
            maximumGlobal: 1,
            maximumIdempotencyReceiptsPerProject: 2,
            maximumIdempotencyReceiptsGlobal: 2
        )
        XCTAssertEqual(compacted, 1)
        let auditRows = try await fixture.runtimeRepository.list(
            context: fixture.context,
            limit: 10
        )
        XCTAssertEqual(auditRows.map(\.jobID), [newestJobID])
        let receipt = try await fixture.runtimeRepository.existingJob(
            projectID: fixture.projectID,
            generation: fixture.context.projectGeneration,
            idempotencyKey: "runtime-ledger-stable-key"
        )
        XCTAssertEqual(receipt?.jobID, originalJobID)
        XCTAssertEqual(receipt?.state, .completed)
        XCTAssertNil(receipt?.outputArtifactID)
        XCTAssertNil(receipt?.processIdentifier)

        let replayedJobID = try await fixture.service.submit(request)
        XCTAssertEqual(replayedJobID, originalJobID)
        let originalText = originalJobID.uuidString.lowercased()
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                textBinding: originalText
            ),
            0
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_idempotency_receipts WHERE job_id=?",
                textBinding: originalText
            ),
            1
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_details WHERE job_id=?",
                textBinding: originalText
            ),
            0
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_output_streams WHERE job_id=?",
                textBinding: originalText
            ),
            0
        )
        await fixture.close()
    }

    func testCompactedIdempotencyReceiptLedgerHonorsProjectAndGlobalCaps() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        var jobIDs: [UUID] = []
        for index in 0..<3 {
            let jobID = try await fixture.service.submit(
                fixture.request(
                    kind: .bash,
                    profile: .bashNoProfile,
                    script: "printf 'receipt-\(index)'",
                    timeout: 5,
                    replayClass: .idempotent,
                    idempotencyKey: "runtime-receipt-cap-\(index)"
                )
            )
            jobIDs.append(jobID)
            _ = try await fixture.service.waitForTerminal(
                jobID: jobID,
                context: fixture.context,
                maximumWait: .seconds(8)
            )
        }

        let compacted = try await fixture.runtimeRepository.compactTerminalJobs(
            maximumPerProject: 1,
            maximumGlobal: 1,
            maximumIdempotencyReceiptsPerProject: 1,
            maximumIdempotencyReceiptsGlobal: 1
        )
        XCTAssertEqual(compacted, 2)
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM execution_jobs"
            ),
            1
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_idempotency_receipts"
            ),
            1
        )
        let oldestReceipt = try await fixture.runtimeRepository.existingJob(
            projectID: fixture.projectID,
            generation: fixture.context.projectGeneration,
            idempotencyKey: "runtime-receipt-cap-0"
        )
        let newestReceipt = try await fixture.runtimeRepository.existingJob(
            projectID: fixture.projectID,
            generation: fixture.context.projectGeneration,
            idempotencyKey: "runtime-receipt-cap-1"
        )
        XCTAssertNil(oldestReceipt)
        XCTAssertEqual(newestReceipt?.jobID, jobIDs[1])
        await fixture.close()
    }

    func testTerminalLedgerDoesNotDeleteDependentsUntilArtifactIsEvicted() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 64,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 100,
            forcedTerminationGraceMilliseconds: 1_000
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let artifactJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf '%600s' retained",
                timeout: 5
            )
        )
        _ = try await fixture.service.waitForTerminal(
            jobID: artifactJobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let newestJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf newest",
                timeout: 5
            )
        )
        _ = try await fixture.service.waitForTerminal(
            jobID: newestJobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )

        let blockedCompaction = try await fixture.runtimeRepository.compactTerminalJobs(
            maximumPerProject: 1,
            maximumGlobal: 100
        )
        XCTAssertEqual(blockedCompaction, 0)
        let retainedJob = try await fixture.runtimeRepository.job(artifactJobID)
        XCTAssertNotNil(retainedJob)
        let output = try await fixture.runtimeRepository.output(
            jobID: artifactJobID,
            stream: .stdout,
            context: fixture.context
        )
        let relativePath = try XCTUnwrap(output.artifactRelativePath)
        let artifactURL = fixture.root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: artifactURL)
        let markedEvicted = try await fixture.runtimeRepository.markArtifactEvicted(
            jobID: artifactJobID,
            stream: .stdout
        )
        XCTAssertTrue(markedEvicted)

        let completedCompaction = try await fixture.runtimeRepository.compactTerminalJobs(
            maximumPerProject: 1,
            maximumGlobal: 100
        )
        XCTAssertEqual(completedCompaction, 1)
        let removedJob = try await fixture.runtimeRepository.job(artifactJobID)
        XCTAssertNil(removedJob)
        let compactedText = artifactJobID.uuidString.lowercased()
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_details WHERE job_id=?",
                textBinding: compactedText
            ),
            0
        )
        XCTAssertEqual(
            try Self.sqliteCount(
                databaseURL: databaseURL,
                sql: "SELECT COUNT(*) FROM runtime_job_output_streams WHERE job_id=?",
                textBinding: compactedText
            ),
            0
        )
        await fixture.close()
    }

    func testClosingUnreleasedParentGateExitsLauncherWithoutExecutingTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-gate-eof-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = projectRoot.appendingPathComponent("must-not-execute")
        let spool = try RuntimeOutputSpool(
            jobID: UUID(),
            projectID: ProjectID(),
            generation: .initial,
            artifactRoot: artifactRoot,
            maximumInlineBytes: 64,
            maximumArtifactBytes: 1_024
        )
        let launcher = try RuntimeLaunchGate.install(serviceRoot: artifactRoot)
        let process = try RuntimeActiveProcess(
            plan: RuntimeProcessPlan(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["--noprofile", "--norc", "-c", "printf leaked > must-not-execute"],
                workingDirectory: projectRoot,
                environment: ["PATH": "/usr/bin:/bin"],
                writableRoots: [projectRoot]
            ),
            spool: spool,
            launcher: launcher
        )
        defer {
            _ = process.signalProcessGroup(SIGKILL)
            spool.discard()
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        process.abortBeforeExecution()
        let observedExit = await process.waitForExit(maximumMilliseconds: 2_000)
        let exit = try XCTUnwrap(observedExit)
        XCTAssertEqual(exit.exitCode, 125)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLaunchGateUsesServiceOwnedCopyAndRejectsWritableOverlap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-gate-install-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let bootstrapRoot = root.appendingPathComponent("bootstrap", isDirectory: true)
        let serviceRoot = root.appendingPathComponent("service", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        for directory in [projectRoot, bootstrapRoot, serviceRoot, artifactRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let trusted = try RuntimeLaunchGate.install(serviceRoot: bootstrapRoot)
        let writableSource = projectRoot.appendingPathComponent("forge-runtime-launcher")
        try Data(contentsOf: trusted).write(to: writableSource, options: .atomic)
        _ = Darwin.chmod(writableSource.path, S_IRWXU)
        let installed = try RuntimeLaunchGate.install(
            serviceRoot: serviceRoot,
            sourceExecutable: writableSource
        )
        try Data("#!/bin/sh\nexit 91\n".utf8).write(to: writableSource, options: .atomic)
        _ = Darwin.chmod(writableSource.path, S_IRWXU)

        let spool = try RuntimeOutputSpool(
            jobID: UUID(),
            projectID: ProjectID(),
            generation: .initial,
            artifactRoot: artifactRoot,
            maximumInlineBytes: 64,
            maximumArtifactBytes: 1_024
        )
        defer { spool.discard() }
        let safePlan = RuntimeProcessPlan(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectory: projectRoot,
            environment: ["PATH": "/usr/bin:/bin"],
            writableRoots: [projectRoot]
        )
        let process = try RuntimeActiveProcess(
            plan: safePlan,
            spool: spool,
            launcher: installed
        )
        try process.releaseForExecution()
        let observedExit = await process.waitForExit(maximumMilliseconds: 2_000)
        XCTAssertEqual(try XCTUnwrap(observedExit).exitCode, 0)
        XCTAssertFalse(installed.path.hasPrefix(projectRoot.path + "/"))

        let overlappingPlan = RuntimeProcessPlan(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectory: projectRoot,
            environment: ["PATH": "/usr/bin:/bin"],
            writableRoots: [root]
        )
        XCTAssertThrowsError(
            try RuntimeActiveProcess(
                plan: overlappingPlan,
                spool: spool,
                launcher: installed
            )
        ) { error in
            XCTAssertEqual((error as? RuntimeJobError)?.code, "invalid_request")
        }
    }

    func testRuntimeLaunchGateRejectsUnrelatedSignedProductIdentity() {
        let unrelated = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try RuntimeLaunchGate.validateProductIdentity(unrelated)) { error in
            guard case RuntimeJobError.storageFailure = error else {
                return XCTFail("unexpected product-identity error: \(error)")
            }
        }
    }

    func testRuntimeLaunchGateAcceptsExactAdHocApplicationPair() throws {
        let appBundle = URL(fileURLWithPath: "/tmp/Forge Conductor.app", isDirectory: true)
        let executable = appBundle.appendingPathComponent("Contents/MacOS/Forge Conductor")
        let helper = appBundle.appendingPathComponent(
            "Contents/Helpers/forge-runtime-launcher"
        )
        let appHash = Data(repeating: 0x41, count: 20)

        XCTAssertNoThrow(
            try RuntimeLaunchGate.validateApplicationProductIdentity(
                source: helper,
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.productIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: Data(repeating: 0x42, count: 20)
                ),
                currentExecutable: executable,
                currentIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: ManagerInstaller.bundleIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: appHash
                ),
                appBundle: appBundle,
                appIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: ManagerInstaller.bundleIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: appHash
                )
            )
        )
    }

    func testRuntimeLaunchGateRejectsAdHocApplicationHelperOutsideExactPath() {
        let appBundle = URL(fileURLWithPath: "/tmp/Forge Conductor.app", isDirectory: true)
        let appHash = Data(repeating: 0x51, count: 20)
        let appIdentity = RuntimeLaunchGate.CodeIdentity(
            identifier: ManagerInstaller.bundleIdentifier,
            teamIdentifier: nil,
            flags: .adhoc,
            uniqueHash: appHash
        )

        XCTAssertThrowsError(
            try RuntimeLaunchGate.validateApplicationProductIdentity(
                source: appBundle.appendingPathComponent("Contents/MacOS/forge-runtime-launcher"),
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.productIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: Data(repeating: 0x52, count: 20)
                ),
                currentExecutable: appBundle.appendingPathComponent(
                    "Contents/MacOS/Forge Conductor"
                ),
                currentIdentity: appIdentity,
                appBundle: appBundle,
                appIdentity: appIdentity
            )
        )
    }

    func testRuntimeLaunchGateRejectsAdHocApplicationIdentityMismatch() {
        let appBundle = URL(fileURLWithPath: "/tmp/Forge Conductor.app", isDirectory: true)
        let executable = appBundle.appendingPathComponent("Contents/MacOS/Forge Conductor")
        let helper = appBundle.appendingPathComponent(
            "Contents/Helpers/forge-runtime-launcher"
        )
        let appIdentity = RuntimeLaunchGate.CodeIdentity(
            identifier: ManagerInstaller.bundleIdentifier,
            teamIdentifier: nil,
            flags: .adhoc,
            uniqueHash: Data(repeating: 0x61, count: 20)
        )

        XCTAssertThrowsError(
            try RuntimeLaunchGate.validateApplicationProductIdentity(
                source: helper,
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: "com.example.unrelated-helper",
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: Data(repeating: 0x62, count: 20)
                ),
                currentExecutable: executable,
                currentIdentity: appIdentity,
                appBundle: appBundle,
                appIdentity: appIdentity
            )
        )

        XCTAssertThrowsError(
            try RuntimeLaunchGate.validateApplicationProductIdentity(
                source: helper,
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.productIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: Data(repeating: 0x63, count: 20)
                ),
                currentExecutable: executable,
                currentIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: ManagerInstaller.bundleIdentifier,
                    teamIdentifier: nil,
                    flags: .adhoc,
                    uniqueHash: Data(repeating: 0x64, count: 20)
                ),
                appBundle: appBundle,
                appIdentity: appIdentity
            )
        )
    }

    func testRuntimeLaunchGateRejectsApplicationSignedByUnapprovedTeam() {
        let appBundle = URL(fileURLWithPath: "/tmp/Forge Conductor.app", isDirectory: true)
        let executable = appBundle.appendingPathComponent("Contents/MacOS/Forge Conductor")
        let helper = appBundle.appendingPathComponent(
            "Contents/Helpers/forge-runtime-launcher"
        )
        let appHash = Data(repeating: 0x71, count: 20)
        let unapprovedTeam = "UNAPPROVED1"

        XCTAssertThrowsError(
            try RuntimeLaunchGate.validateApplicationProductIdentity(
                source: helper,
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.productIdentifier,
                    teamIdentifier: unapprovedTeam,
                    flags: [],
                    uniqueHash: Data(repeating: 0x72, count: 20)
                ),
                currentExecutable: executable,
                currentIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: ManagerInstaller.bundleIdentifier,
                    teamIdentifier: unapprovedTeam,
                    flags: [],
                    uniqueHash: appHash
                ),
                appBundle: appBundle,
                appIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: ManagerInstaller.bundleIdentifier,
                    teamIdentifier: unapprovedTeam,
                    flags: [],
                    uniqueHash: appHash
                )
            )
        )
    }

    func testLaunchGateParentCrashClosesGateWithoutExecutingTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-gate-crash-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let serviceRoot = root.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = try RuntimeLaunchGate.install(serviceRoot: serviceRoot)
        let source = projectRoot.appendingPathComponent("gate-crash-harness.c")
        let harness = projectRoot.appendingPathComponent("gate-crash-harness")
        let pidFile = projectRoot.appendingPathComponent("launcher.pid")
        let marker = projectRoot.appendingPathComponent("must-not-run")
        let program = """
        #include <fcntl.h>
        #include <spawn.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        extern char **environ;

        int main(int argc, char **argv) {
            if (argc != 4) return 64;
            int gate[2];
            if (pipe(gate) != 0) return 65;
            posix_spawn_file_actions_t actions;
            posix_spawnattr_t attributes;
            if (posix_spawn_file_actions_init(&actions) != 0) return 66;
            if (posix_spawnattr_init(&attributes) != 0) return 67;
            if (posix_spawn_file_actions_adddup2(&actions, gate[0], 3) != 0) return 68;
            if (posix_spawn_file_actions_addclose(&actions, gate[1]) != 0) return 69;
            short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT;
            if (posix_spawnattr_setflags(&attributes, flags) != 0) return 70;
            if (posix_spawnattr_setpgroup(&attributes, 0) != 0) return 71;
            char parent[32];
            snprintf(parent, sizeof(parent), "%d", getpid());
            char *child_argv[] = {
                argv[1], "--parent", parent, "--", "/bin/sh", "-c",
                "printf crashed > \\\"$1\\\"", "sh", argv[3], NULL
            };
            pid_t child = 0;
            int result = posix_spawn(
                &child, argv[1], &actions, &attributes, child_argv, environ
            );
            if (result != 0) return 72;
            close(gate[0]);
            int descriptor = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (descriptor < 0) return 73;
            char buffer[32];
            int length = snprintf(buffer, sizeof(buffer), "%d\\n", child);
            if (write(descriptor, buffer, (size_t)length) != (ssize_t)length) return 74;
            fsync(descriptor);
            close(descriptor);
            _exit(0);
        }
        """
        try program.write(to: source, atomically: true, encoding: .utf8)
        let compilation = try ProcessRunner().run(
            executable: "/usr/bin/clang",
            arguments: ["-Wall", "-Wextra", "-Werror", source.path, "-o", harness.path],
            timeoutSec: 30
        )
        XCTAssertEqual(compilation.exitCode, 0, compilation.stderr)
        let result = try ProcessRunner().run(
            executable: harness.path,
            arguments: [launcher.path, pidFile.path, marker.path],
            currentDirectory: projectRoot.path,
            timeoutSec: 5
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let child = try Self.readPID(pidFile)
        let childGone = await Self.waitUntilProcessIsGone(child)
        XCTAssertTrue(childGone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRecoveryKillsCommittedLauncherBeforeGateReleaseWithoutExecutingTarget() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        let request = fixture.request(
            kind: .bash,
            profile: .bashNoProfile,
            script: "printf leaked > recovery-gate-marker",
            timeout: 30
        )
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: request,
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=37",
            timeoutSeconds: 30,
            requestArtifactRelativePath: nil
        )
        let artifactRoot = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
        let spool = try RuntimeOutputSpool(
            jobID: jobID,
            projectID: fixture.projectID,
            generation: fixture.context.projectGeneration,
            artifactRoot: artifactRoot,
            maximumInlineBytes: 64,
            maximumArtifactBytes: 1_024
        )
        defer { spool.discard() }
        let launcher = try RuntimeLaunchGate.install(serviceRoot: artifactRoot)
        let process = try RuntimeActiveProcess(
            plan: RuntimeProcessPlan(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    "--noprofile", "--norc", "-c",
                    "printf leaked > recovery-gate-marker",
                ],
                workingDirectory: fixture.projectRoot,
                environment: ["PATH": "/usr/bin:/bin"],
                writableRoots: [fixture.projectRoot]
            ),
            spool: spool,
            launcher: launcher
        )
        let startIdentity = try XCTUnwrap(process.processStartIdentity)
        try await fixture.runtimeRepository.markRunning(
            jobID: jobID,
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier,
            processStartIdentity: startIdentity
        )
        await fixture.service.shutdown()

        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: artifactRoot,
            limits: fixture.limits
        )
        try await recoveringService.start()
        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.errorCode, "runtime_owner_restarted")
        let observedExit = await process.waitForExit(maximumMilliseconds: 2_000)
        XCTAssertNotNil(observedExit)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.projectRoot.appendingPathComponent("recovery-gate-marker").path
            )
        )
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testRecoveredProcessControllerRejectsTamperedProcessStartIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-identity-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(
            jobID: UUID(),
            projectID: ProjectID(),
            generation: .initial,
            artifactRoot: artifactRoot,
            maximumInlineBytes: 64,
            maximumArtifactBytes: 1_024
        )
        let launcher = try RuntimeLaunchGate.install(serviceRoot: artifactRoot)
        let process = try RuntimeActiveProcess(
            plan: RuntimeProcessPlan(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                workingDirectory: projectRoot,
                environment: ["PATH": "/usr/bin:/bin"],
                writableRoots: [projectRoot]
            ),
            spool: spool,
            launcher: launcher
        )
        try process.releaseForExecution()
        defer {
            _ = process.signalProcessGroup(SIGKILL)
            spool.discard()
        }
        let start = try XCTUnwrap(process.processStartIdentity)
        let changedMicroseconds = start.microseconds == 999_999 ? 999_998 : start.microseconds + 1
        let tamperedStart = try XCTUnwrap(RuntimeProcessStartIdentity(
            seconds: start.seconds,
            microseconds: changedMicroseconds
        ))
        let result = await DarwinRuntimeRecoveredProcessController().signalProcessGroup(
            SIGTERM,
            expectedIdentity: RuntimePersistedProcessIdentity(
                processIdentifier: process.processIdentifier,
                processGroupIdentifier: process.processGroupIdentifier,
                startIdentity: tamperedStart
            )
        )
        XCTAssertEqual(result, .identityMismatch)
        let unexpectedExit = await process.waitForExit(maximumMilliseconds: 100)
        XCTAssertNil(unexpectedExit)
    }

    func testRecoveredProcessControllerKillsOwnedGroupAfterLeaderExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-orphan-group-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(
            jobID: UUID(),
            projectID: ProjectID(),
            generation: .initial,
            artifactRoot: artifactRoot,
            maximumInlineBytes: 64,
            maximumArtifactBytes: 1_024
        )
        let pidFile = projectRoot.appendingPathComponent("orphan.pid")
        let launcher = try RuntimeLaunchGate.install(serviceRoot: artifactRoot)
        let process = try RuntimeActiveProcess(
            plan: RuntimeProcessPlan(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    "--noprofile", "--norc", "-c",
                    "(trap '' TERM; while :; do sleep 1; done) & echo $! > orphan.pid",
                ],
                workingDirectory: projectRoot,
                environment: ["PATH": "/usr/bin:/bin"],
                writableRoots: [projectRoot]
            ),
            spool: spool,
            launcher: launcher
        )
        try process.releaseForExecution()
        defer {
            _ = process.signalProcessGroup(SIGKILL)
            spool.discard()
        }
        let startIdentity = try XCTUnwrap(process.processStartIdentity)
        let identity = RuntimePersistedProcessIdentity(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier,
            startIdentity: startIdentity
        )
        let pidFileReady = await Self.waitForFile(pidFile)
        XCTAssertTrue(pidFileReady)
        _ = await process.waitForExit(maximumMilliseconds: 2_000)
        let descendant = try Self.readPID(pidFile)
        let result = await DarwinRuntimeRecoveredProcessController().signalProcessGroup(
            SIGKILL,
            expectedIdentity: identity
        )
        XCTAssertEqual(result, .signaled)
        let descendantGone = await Self.waitUntilProcessIsGone(descendant)
        XCTAssertTrue(descendantGone)
    }

    func testStartupRecoveryWithoutExactStartIdentityFailsClosedAndKeepsOwnership() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 30",
                timeout: 30
            ),
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=8",
            timeoutSeconds: 30,
            requestArtifactRelativePath: nil
        )
        try await fixture.runtimeRepository.markRunning(
            jobID: jobID,
            processIdentifier: 424_242,
            processGroupIdentifier: 424_242,
            processStartIdentity: nil
        )
        let signalProbe = RecoveredSignalProbe(result: .signaled)
        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await recoveringService.setRecoveredProcessController(signalProbe)
        do {
            try await recoveringService.start()
            XCTFail("recovery without exact process identity unexpectedly terminalized the job")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }

        let signals = await signalProbe.signals()
        XCTAssertTrue(signals.isEmpty)
        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .running)
        XCTAssertNil(recovered?.completedAt)
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testStartupRecoveryKeepsJobNonterminalUntilProcessGroupDeathIsConfirmed() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 256,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 20,
            forcedTerminationGraceMilliseconds: 20
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 30",
                timeout: 30
            ),
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=8",
            timeoutSeconds: 30,
            requestArtifactRelativePath: nil
        )
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 100, microseconds: 1))
        try await fixture.runtimeRepository.markRunning(
            jobID: jobID,
            processIdentifier: 424_242,
            processGroupIdentifier: 424_242,
            processStartIdentity: start
        )
        let signalProbe = RecoveredSignalProbe(result: .signaled)
        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: limits
        )
        try await recoveringService.setRecoveredProcessController(signalProbe)
        do {
            try await recoveringService.start()
            XCTFail("unconfirmed process-group cleanup unexpectedly passed")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_termination_unconfirmed")
        }
        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .running)
        XCTAssertNil(recovered?.completedAt)
        let termination = try await fixture.runtimeRepository.terminationRecord(jobID: jobID)
        XCTAssertEqual(termination?.phase, .unconfirmed)
        XCTAssertNotNil(termination?.probeDeadline)
        let signals = await signalProbe.signals()
        XCTAssertTrue(signals.contains(SIGTERM))
        XCTAssertTrue(signals.contains(SIGKILL))
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testStartupRecoveryWaitsThroughTransientIdentityUnavailableProbe() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 30",
                timeout: 30
            ),
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=8",
            timeoutSeconds: 30,
            requestArtifactRelativePath: nil
        )
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 100, microseconds: 1))
        try await fixture.runtimeRepository.markRunning(
            jobID: jobID,
            processIdentifier: 424_242,
            processGroupIdentifier: 424_242,
            processStartIdentity: start
        )
        let signalProbe = TransientIdentityUnavailableRecoveredProcessController()
        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await recoveringService.setRecoveredProcessController(signalProbe)

        try await recoveringService.start()

        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.errorCode, "runtime_owner_restarted")
        let signals = await signalProbe.signals()
        XCTAssertEqual(signals, [SIGTERM, 0, 0])
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testStartupRecoveryRetriesTransientIdentityUnavailableDuringForcedKill() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 256,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 20,
            forcedTerminationGraceMilliseconds: 100
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 30",
                timeout: 30
            ),
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=8",
            timeoutSeconds: 30,
            requestArtifactRelativePath: nil
        )
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 100, microseconds: 1))
        try await fixture.runtimeRepository.markRunning(
            jobID: jobID,
            processIdentifier: 424_243,
            processGroupIdentifier: 424_243,
            processStartIdentity: start
        )
        let signalProbe = ForcedTransientIdentityUnavailableRecoveredProcessController()
        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: limits
        )
        try await recoveringService.setRecoveredProcessController(signalProbe)

        try await recoveringService.start()

        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.errorCode, "runtime_owner_restarted")
        let signals = await signalProbe.signals()
        XCTAssertEqual(signals.first, SIGTERM)
        XCTAssertTrue(signals.contains(0))
        XCTAssertEqual(signals.filter { $0 == SIGKILL }.count, 2)
        XCTAssertEqual(Array(signals.suffix(2)), [SIGKILL, SIGKILL])
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testCancelJobsForRunReleasesOnlyThatRunsQueuedAndActiveJobs() async throws {
        let limits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 4,
            maximumInlineOutputBytes: 256,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 100,
            forcedTerminationGraceMilliseconds: 1_000
        )
        let fixture = try await Fixture.make(limits: limits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstRun = try await fixture.autonomousRunContext(mission: "Cancel runtime owners")
        let secondRun = try await fixture.autonomousRunContext(mission: "Preserve unrelated runtime owner")

        let activeJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 30",
                timeout: 30,
                context: firstRun.context
            )
        )
        let activeReachedRunning = await fixture.waitForState(
            activeJobID,
            expected: .running,
            context: firstRun.context
        )
        XCTAssertTrue(activeReachedRunning)
        let queuedJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf should-not-run",
                timeout: 5,
                context: firstRun.context
            )
        )
        let unrelatedJobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf unrelated",
                timeout: 5,
                context: secondRun.context
            )
        )

        let cancelledCount = try await fixture.service.cancelJobs(runID: firstRun.runID)
        XCTAssertEqual(cancelledCount, 2)
        let activeRecord = try await fixture.runtimeRepository.job(activeJobID)
        let queuedRecord = try await fixture.runtimeRepository.job(queuedJobID)
        XCTAssertEqual(activeRecord?.state, .cancelled)
        XCTAssertEqual(queuedRecord?.state, .cancelled)
        let unrelated = try await fixture.service.waitForTerminal(
            jobID: unrelatedJobID,
            context: secondRun.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(unrelated.state, .completed)
        await fixture.close()
    }

    func testStartupRecoveryRemovesInterruptedArtifactsAndMarksDurableFailure() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = UUID()
        let relativeDirectory = [
            fixture.projectID.description,
            String(fixture.context.projectGeneration.rawValue),
            jobID.uuidString.lowercased(),
        ].joined(separator: "/")
        let requestRelativePath = relativeDirectory + "/request.bash"
        let artifactRoot = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
        let jobDirectory = artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        try Data("printf recovery".utf8).write(
            to: artifactRoot.appendingPathComponent(requestRelativePath)
        )
        try Data("partial output".utf8).write(
            to: jobDirectory.appendingPathComponent("stdout.log")
        )
        _ = try await fixture.runtimeRepository.createJob(
            jobID: jobID,
            request: fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "printf recovery",
                timeout: 5
            ),
            commandSummary: "bash_no_profile:bash:argv=3:script_bytes=15",
            timeoutSeconds: 5,
            requestArtifactRelativePath: requestRelativePath
        )

        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: artifactRoot,
            limits: fixture.limits
        )
        try await recoveringService.start()
        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.errorCode, "runtime_owner_restarted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobDirectory.path))
        let retainedRequestPath = try await fixture.runtimeRepository.requestArtifactRelativePath(
            jobID: jobID
        )
        XCTAssertNil(retainedRequestPath)
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testArtifactReservationsKeepProjectAndGlobalRetentionWithinQuota() async throws {
        let quotaLimits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 64,
            maximumArtifactBytesPerJob: 1_500,
            maximumArtifactBytesPerProject: 2_000,
            maximumArtifactBytesGlobal: 2_200,
            maximumRetainedArtifactJobsPerProject: 10,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 100,
            forcedTerminationGraceMilliseconds: 1_000
        )
        let fixture = try await Fixture.make(limits: quotaLimits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for _ in 0..<2 {
            let jobID = try await fixture.service.submit(
                fixture.request(
                    kind: .bash,
                    profile: .bashNoProfile,
                    script: "printf '%1200s' x",
                    timeout: 5
                )
            )
            let record = try await fixture.service.waitForTerminal(
                jobID: jobID,
                context: fixture.context,
                maximumWait: .seconds(8)
            )
            XCTAssertEqual(record.state, .completed)
        }
        let projectBytes = try await fixture.runtimeRepository.retainedArtifactBytes(
            projectID: fixture.projectID
        )
        let globalBytes = try await fixture.runtimeRepository.retainedArtifactBytes()
        XCTAssertLessThanOrEqual(projectBytes, UInt64(quotaLimits.maximumArtifactBytesPerProject))
        XCTAssertLessThanOrEqual(globalBytes, UInt64(quotaLimits.maximumArtifactBytesGlobal))
        await fixture.close()
    }

    func testCompletedArtifactRetentionCompactsOldestJob() async throws {
        let compactingLimits = RuntimeJobLimits(
            maximumConcurrentJobs: 1,
            maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2,
            maximumInlineOutputBytes: 64,
            maximumArtifactBytesPerJob: 4 * 1_024,
            maximumArtifactBytesPerProject: 16 * 1_024,
            maximumArtifactBytesGlobal: 16 * 1_024,
            maximumRetainedArtifactJobsPerProject: 1,
            maximumScriptBytes: 8 * 1_024,
            maximumArguments: 32,
            maximumArgumentBytes: 4 * 1_024,
            maximumTimeoutSeconds: 30,
            terminationGraceMilliseconds: 100,
            forcedTerminationGraceMilliseconds: 1_000
        )
        let fixture = try await Fixture.make(limits: compactingLimits)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var jobIDs: [UUID] = []
        for marker in ["first", "second"] {
            let jobID = try await fixture.service.submit(
                fixture.request(
                    kind: .bash,
                    profile: .bashNoProfile,
                    script: "printf '%600s' \(marker)",
                    timeout: 5
                )
            )
            jobIDs.append(jobID)
            let record = try await fixture.service.waitForTerminal(
                jobID: jobID,
                context: fixture.context,
                maximumWait: .seconds(8)
            )
            XCTAssertEqual(record.state, .completed)
        }
        let retainedCount = try await fixture.runtimeRepository.retainedArtifactJobCount(
            projectID: fixture.projectID
        )
        XCTAssertEqual(retainedCount, 1)
        let oldest = try await fixture.runtimeRepository.output(
            jobID: jobIDs[0],
            stream: .stdout,
            context: fixture.context
        )
        XCTAssertTrue(oldest.artifactEvicted)
        do {
            _ = try await fixture.service.readOutput(
                jobID: jobIDs[0],
                stream: .stdout,
                offset: 0,
                limit: 128,
                context: fixture.context
            )
            XCTFail("compacted artifact unexpectedly remained readable")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_artifact_evicted")
        }
        await fixture.close()
    }

    func testArtifactReadRejectsSymlinkReplacementOutsideArtifactRoot() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "i=0; while [ \"$i\" -lt 2000 ]; do printf x; i=$((i + 1)); done",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let metadata = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        let relativePath = try XCTUnwrap(metadata.artifactRelativePath)
        let artifact = fixture.root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(relativePath)
        let outside = fixture.root.appendingPathComponent("outside-artifact-secret")
        try Data("must-not-be-read".utf8).write(to: outside, options: .atomic)
        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: outside)

        do {
            _ = try await fixture.service.readOutput(
                jobID: jobID,
                stream: .stdout,
                offset: 0,
                limit: 1024,
                context: fixture.context
            )
            XCTFail("symlinked output artifact unexpectedly remained readable")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_artifact_evicted")
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("must-not-be-read".utf8))
        await fixture.close()
    }

    func testArtifactReadRejectsSameDirectoryReplacementEvenWhenDigestMatches() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "i=0; while [ \"$i\" -lt 2000 ]; do printf x; i=$((i + 1)); done",
                timeout: 5
            )
        )
        _ = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let metadata = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        let relativePath = try XCTUnwrap(metadata.artifactRelativePath)
        let persistedFileID = try XCTUnwrap(metadata.artifactFileIdentifier)
        XCTAssertNotNil(metadata.artifactDeviceIdentifier)
        let artifact = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(relativePath)
        let original = try Data(contentsOf: artifact)
        try FileManager.default.removeItem(at: artifact)
        try original.write(to: artifact, options: .atomic)
        _ = Darwin.chmod(artifact.path, S_IRUSR | S_IWUSR)
        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
        let replacementFileID = try XCTUnwrap(
            (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        XCTAssertNotEqual(replacementFileID, persistedFileID)

        do {
            _ = try await fixture.service.readOutput(
                jobID: jobID,
                stream: .stdout,
                offset: 0,
                limit: 1_024,
                context: fixture.context
            )
            XCTFail("same-directory artifact replacement unexpectedly verified")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }
        await fixture.close()
    }

    func testArtifactReadRejectsInPlaceMutationByDigest() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "i=0; while [ \"$i\" -lt 2000 ]; do printf x; i=$((i + 1)); done",
                timeout: 5
            )
        )
        _ = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let metadata = try await fixture.runtimeRepository.output(
            jobID: jobID,
            stream: .stdout,
            context: fixture.context
        )
        let relativePath = try XCTUnwrap(metadata.artifactRelativePath)
        let artifact = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: artifact)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x7a, count: Int(metadata.retainedByteCount)))
        try handle.synchronize()
        try handle.close()

        do {
            _ = try await fixture.service.readOutput(
                jobID: jobID,
                stream: .stdout,
                offset: 0,
                limit: 1_024,
                context: fixture.context
            )
            XCTFail("mutated artifact unexpectedly passed digest verification")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }
        await fixture.close()
    }

    func testStartupSweepsBoundedOrphanDurableAndScratchDirectories() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.service.shutdown()

        let orphanJobID = UUID()
        let relative = [
            fixture.projectID.description,
            String(fixture.context.projectGeneration.rawValue),
            orphanJobID.uuidString.lowercased(),
        ].joined(separator: "/")
        let artifacts = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
        let durableOrphan = artifacts.appendingPathComponent(relative, isDirectory: true)
        let scratchOrphan = artifacts.appendingPathComponent(
            ".runtime-scratch/" + relative,
            isDirectory: true
        )
        for directory in [durableOrphan, scratchOrphan] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("orphan".utf8).write(
                to: directory.appendingPathComponent("orphan"),
                options: .atomic
            )
        }

        let recoveringService = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: artifacts,
            limits: fixture.limits
        )
        try await recoveringService.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableOrphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchOrphan.path))
        await recoveringService.shutdown()
        await fixture.close()
    }

    func testMissingOptionalRuntimesAreDiscoveredIndependentlyWithoutDisablingShell() async throws {
        let limits = Self.testLimits
        let baseline = RuntimeCapabilityDiscoverer().discover(limits: limits)
        let bothMissing = RuntimeCapabilityDiscoverer(
            configuredPython: URL(fileURLWithPath: "/definitely/missing/python3"),
            configuredPowerShell: URL(fileURLWithPath: "/definitely/missing/pwsh")
        ).discover(limits: limits)
        XCTAssertTrue(bothMissing.directProcess.available)
        XCTAssertTrue(bothMissing.zsh.available)
        XCTAssertTrue(bothMissing.bash.available)
        XCTAssertTrue(bothMissing.shellAvailable)
        XCTAssertFalse(bothMissing.python.available)
        XCTAssertFalse(bothMissing.powershell.available)

        let pythonMissing = RuntimeCapabilityDiscoverer(
            configuredPython: URL(fileURLWithPath: "/definitely/missing/python3")
        ).discover(limits: limits)
        XCTAssertFalse(pythonMissing.python.available)
        XCTAssertEqual(pythonMissing.powershell, baseline.powershell)
        XCTAssertTrue(pythonMissing.shellAvailable)

        let powershellMissing = RuntimeCapabilityDiscoverer(
            configuredPowerShell: URL(fileURLWithPath: "/definitely/missing/pwsh")
        ).discover(limits: limits)
        XCTAssertEqual(powershellMissing.python, baseline.python)
        XCTAssertFalse(powershellMissing.powershell.available)
        XCTAssertTrue(powershellMissing.shellAvailable)

        let configuredShim = RuntimeCapabilityDiscoverer(
            configuredPython: URL(fileURLWithPath: "/usr/bin/python3"),
            configuredPowerShell: URL(fileURLWithPath: "/definitely/missing/pwsh")
        ).discover(limits: limits)
        XCTAssertTrue(configuredShim.python.available)
        XCTAssertNotEqual(configuredShim.python.executablePath, "/usr/bin/python3")

        let mutableRuntime = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-mutable-pwsh-\(UUID().uuidString)")
        try Data("not-a-runtime".utf8).write(to: mutableRuntime, options: .atomic)
        _ = Darwin.chmod(mutableRuntime.path, S_IRWXU)
        defer { try? FileManager.default.removeItem(at: mutableRuntime) }
        let rejectedMutableRuntime = RuntimeCapabilityDiscoverer(
            configuredPowerShell: mutableRuntime
        ).discover(limits: limits)
        XCTAssertFalse(rejectedMutableRuntime.powershell.available)
    }

    func testOptionalRuntimeDiscoveryRejectsUnrelatedImmutableExecutables() {
        let capabilities = RuntimeCapabilityDiscoverer(
            configuredPython: URL(fileURLWithPath: "/usr/bin/true"),
            configuredPowerShell: URL(fileURLWithPath: "/usr/bin/true")
        ).discover(limits: Self.testLimits)

        XCTAssertFalse(capabilities.python.available)
        XCTAssertNil(capabilities.python.executablePath)
        XCTAssertFalse(capabilities.python.required)
        XCTAssertFalse(capabilities.powershell.available)
        XCTAssertNil(capabilities.powershell.executablePath)
        XCTAssertFalse(capabilities.powershell.required)
        XCTAssertTrue(capabilities.shellAvailable)
    }

    func testAdvertisedPythonProfileExecutesTheRealInterpreterUnderContainment() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capability = await fixture.service.capabilities().python
        guard capability.available else {
            throw XCTSkip("No contained Python interpreter is available on this host")
        }
        XCTAssertNotEqual(capability.executablePath, "/usr/bin/python3")
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .python,
                profile: .pythonIsolated,
                script: "print('python-contained')",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        let diagnostic = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stderr,
            offset: 0,
            limit: 4_096,
            context: fixture.context
        )
        let diagnosticText = String(decoding: diagnostic.data, as: UTF8.self)
        XCTAssertEqual(record.state, .completed, diagnosticText)
        XCTAssertEqual(record.exitCode, 0, diagnosticText)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "python-contained\n")
        await fixture.close()
    }

    func testAdvertisedPowerShellProfileExecutesWithoutProcessGroupEscape() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capability = await fixture.service.capabilities().powershell
        guard capability.available else {
            throw XCTSkip("PowerShell is not installed on this host")
        }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .powershell,
                profile: .powershellNoProfile,
                script: "[Console]::Out.Write('powershell-contained')",
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testDelayedResultAfterGenerationResetIsQuarantined() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "sleep 0.4; printf 'delayed-result'",
                timeout: 5
            )
        )
        let reachedRunning = await fixture.waitForState(jobID, expected: .running)
        XCTAssertTrue(reachedRunning)
        _ = try await fixture.controlRepository.beginReset(
            projectID: fixture.projectID,
            expectedGeneration: .initial
        )
        _ = try await fixture.controlRepository.completeReset(
            projectID: fixture.projectID,
            expectedGeneration: .initial
        )
        let quarantined = await fixture.waitForRepositoryState(jobID, expected: .quarantinedStale)
        XCTAssertTrue(quarantined)
        let record = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(record?.state, .quarantinedStale)
        XCTAssertEqual(record?.errorCode, "stale_project_generation")
        let quarantineCount = try await fixture.controlRepository.quarantineEventCount(
            projectID: fixture.projectID
        )
        XCTAssertEqual(quarantineCount, 1)
        await fixture.close()
    }

    func testOutsideRootIsRejectedBeforeJobPersistence() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let request = RuntimeJobRequest(
            kind: .process,
            profile: .directProcess,
            context: fixture.context,
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            canonicalWorkingDirectory: outside,
            timeout: .seconds(2),
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
            replayClass: .readOnly
        )
        do {
            _ = try await fixture.service.submit(request)
            XCTFail("outside-root submission unexpectedly succeeded")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "cwd_outside_authorized_roots")
        }
        let records = try await fixture.runtimeRepository.list(context: fixture.context)
        XCTAssertTrue(records.isEmpty)
        await fixture.close()
    }

    func testRuntimeSandboxDeniesFileAccessOutsideAuthorizedRoots() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-secret.txt")
        try Data("outside-secret".utf8).write(to: outside, options: .atomic)
        let script = "cat '\(outside.path)'; printf overwritten > '\(outside.path)'"
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: script,
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertNotEqual(record.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-secret".utf8))
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertFalse(String(decoding: output.data, as: UTF8.self).contains("outside-secret"))
        await fixture.close()
    }

    func testRuntimeLauncherClosesGateAndUnrelatedInheritedDescriptorsBeforeExec() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("inherited-secret.txt")
        try Data("inherited-secret".utf8).write(to: outside, options: .atomic)
        let original = Darwin.open(outside.path, O_RDONLY)
        guard original >= 0 else {
            throw RuntimeJobError.storageFailure("could not open inherited-descriptor fixture")
        }
        let inherited = Darwin.fcntl(original, F_DUPFD, 100)
        Darwin.close(original)
        guard inherited >= 100 else {
            throw RuntimeJobError.storageFailure("could not allocate high inherited descriptor")
        }
        defer { Darwin.close(inherited) }
        _ = Darwin.fcntl(inherited, F_SETFD, 0)

        let script = """
        if /bin/cat <&3 >/dev/null 2>&1; then exit 91; fi
        if /bin/cat <&\(inherited) >/dev/null 2>&1; then exit 92; fi
        printf 'descriptors-closed'
        """
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: script,
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "descriptors-closed")
        await fixture.close()
    }

    func testRuntimeSandboxAncestorTraversalDoesNotPermitSiblingEnumeration() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sibling = fixture.root.appendingPathComponent("sibling-secret")
        try Data("sibling".utf8).write(to: sibling, options: .atomic)
        let script = """
        if /bin/ls '\(fixture.root.path)' >/dev/null 2>&1; then exit 91; fi
        printf 'enumeration-denied'
        """
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: script,
                timeout: 5
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "enumeration-denied")
        await fixture.close()
    }

    func testRuntimeSandboxDeniesProcessGroupEscapeSyscalls() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-MPOSIX",
                    "-e",
                    "exit(POSIX::setsid() == -1 ? 0 : 91)",
                ],
                canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testRuntimeSandboxDeniesPosixSpawnWithNewProcessGroup() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.projectRoot.appendingPathComponent("spawn-probe.c")
        let executable = fixture.projectRoot.appendingPathComponent("spawn-probe")
        let program = """
        #include <errno.h>
        #include <signal.h>
        #include <spawn.h>
        #include <sys/wait.h>
        #include <unistd.h>

        extern char **environ;

        int main(void) {
            posix_spawnattr_t attributes;
            if (posix_spawnattr_init(&attributes) != 0) return 80;
            if (posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP) != 0) return 81;
            if (posix_spawnattr_setpgroup(&attributes, 0) != 0) return 82;
            pid_t child = 0;
            char *arguments[] = { "/usr/bin/true", NULL };
            int result = posix_spawn(
                &child,
                "/usr/bin/true",
                NULL,
                &attributes,
                arguments,
                environ
            );
            posix_spawnattr_destroy(&attributes);
            if (result == EPERM) return 0;
            if (result == 0) {
                kill(-child, SIGKILL);
                waitpid(child, NULL, 0);
                return 91;
            }
            return 92;
        }
        """
        try program.write(to: source, atomically: true, encoding: .utf8)
        let compilation = try ProcessRunner().run(
            executable: "/usr/bin/clang",
            arguments: ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path],
            timeoutSec: 30
        )
        XCTAssertEqual(compilation.exitCode, 0, compilation.stderr)

        let jobID = try await fixture.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: executable,
                arguments: [],
                canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testRuntimeSandboxEnforcesNetworkAuthorizationBit() async throws {
        let listener = try Self.makeLoopbackListener()
        defer { Darwin.close(listener.descriptor) }

        let denied = try await Fixture.make(networkAllowed: false)
        defer { try? FileManager.default.removeItem(at: denied.root) }
        let deniedJob = try await denied.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: denied.context,
                executable: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-z", "-G", "1", "127.0.0.1", String(listener.port)],
                canonicalWorkingDirectory: denied.projectRoot,
                timeout: .seconds(3),
                maximumInlineOutputBytes: denied.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let deniedRecord = try await denied.service.waitForTerminal(
            jobID: deniedJob,
            context: denied.context,
            maximumWait: .seconds(6)
        )
        XCTAssertEqual(deniedRecord.state, .failed)
        XCTAssertNotEqual(deniedRecord.exitCode, 0)
        await denied.close()

        let allowed = try await Fixture.make(networkAllowed: true)
        defer { try? FileManager.default.removeItem(at: allowed.root) }
        let allowedJob = try await allowed.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: allowed.context,
                executable: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-z", "-G", "1", "127.0.0.1", String(listener.port)],
                canonicalWorkingDirectory: allowed.projectRoot,
                timeout: .seconds(3),
                maximumInlineOutputBytes: allowed.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let allowedRecord = try await allowed.service.waitForTerminal(
            jobID: allowedJob,
            context: allowed.context,
            maximumWait: .seconds(6)
        )
        XCTAssertEqual(allowedRecord.state, .completed)
        XCTAssertEqual(allowedRecord.exitCode, 0)
        await allowed.close()
    }

    func testRuntimeNetworkAuthorizationStillDeniesUnixSocketBrokers() async throws {
        let token = UUID().uuidString.prefix(12).lowercased()
        let socketURL = URL(fileURLWithPath: "/tmp/fc-unix-\(token).sock")
        let listener = try Self.makeUnixListener(
            at: socketURL
        )
        defer {
            Darwin.close(listener.descriptor)
            _ = Darwin.unlink(listener.path)
        }

        let fixture = try await Fixture.make(networkAllowed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-U", listener.path],
                canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(2),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(5)
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertNotEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testRuntimeSandboxBlocksMachBrokerDelegationEvenWhenNetworkIsAllowed() async throws {
        let fixture = try await Fixture.make(networkAllowed: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["list-keychains"],
                canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(3),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(6)
        )
        XCTAssertEqual(record.state, .failed)
        XCTAssertNotEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testRuntimeSandboxProfileIsDenyByDefaultAndExcludesMutableUSRPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-profile-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try RuntimeProcessSandbox.plan(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ok"],
            workingDirectory: project,
            environment: [:],
            canonicalReadRoots: [project],
            canonicalWritableRoots: [project],
            managerReadDirectory: artifacts,
            scratchDirectory: scratch,
            networkAllowed: false
        )
        let profile = try XCTUnwrap(plan.arguments.dropFirst().first)
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertFalse(profile.contains("(allow default)"))
        XCTAssertFalse(profile.contains("(allow mach"))
        XCTAssertFalse(profile.contains("(subpath \"/usr\")"))
        XCTAssertTrue(profile.contains("(subpath \"/usr/bin\")"))
        XCTAssertTrue(profile.contains("(deny syscall-unix (syscall-number 82 147 244))"))
        XCTAssertTrue(profile.contains("allow file-read-metadata file-test-existence"))
        XCTAssertFalse(profile.contains("(allow network"))
        XCTAssertFalse(profile.contains("system-socket"))
    }

    func testRuntimeSandboxRejectsManagerOutputInsideChildWritableRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-output-overlap-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let artifacts = project.appendingPathComponent("runtime-artifacts/job", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        for directory in [project, artifacts, scratch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try RuntimeProcessSandbox.plan(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["blocked"],
                workingDirectory: project,
                environment: [:],
                canonicalReadRoots: [project],
                canonicalWritableRoots: [project],
                managerReadDirectory: artifacts,
                scratchDirectory: scratch,
                networkAllowed: false
            )
        ) { error in
            XCTAssertEqual((error as? RuntimeJobError)?.code, "invalid_request")
            XCTAssertTrue(error.localizedDescription.contains("durable output"))
        }
    }

    func testLegacyBashLoginCompatibilityProfileIsExposedWithoutChangingShellToolPack() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submitLegacyBashLogin(
            command: "printf 'legacy-profile'",
            workingDirectory: fixture.projectRoot,
            timeoutSeconds: 5,
            context: fixture.context,
            replayClass: .readOnly
        )
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.executionProfile, .legacyBashLogin)
        XCTAssertEqual(record.state, .completed)
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "legacy-profile")
        XCTAssertEqual(Set(RuntimeJobToolPack.names), Set([
            "runtime.capabilities", "process.run", "shell.run", "bash.run", "python.run",
            "powershell.run", "job.status", "job.read_output", "job.cancel", "job.list",
        ]))
        for name in RuntimeJobToolPack.names {
            XCTAssertNotNil(RuntimeJobToolPack.description(for: name))
            XCTAssertNotNil(RuntimeJobToolPack.schema(for: name))
        }

        let legacy = LegacyShellJobAdapter(service: fixture.service)
        let result = try await legacy.execute(
            command: "printf 'legacy-adapter'",
            workingDirectory: fixture.projectRoot,
            timeoutSeconds: 999,
            context: fixture.context
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload["stdout"] as? String, "legacy-adapter")
        XCTAssertEqual(Set(result.payload.keys), Set([
            "ok", "exit_code", "stdout", "stderr", "timed_out", "stdout_truncated",
            "stderr_truncated", "command", "cwd",
        ]))
        let records = try await fixture.service.list(context: fixture.context)
        XCTAssertTrue(records.contains {
            $0.executionProfile == .legacyBashLogin
                && $0.timeoutSeconds == min(
                    LegacyShellJobAdapter.maximumTimeoutSeconds,
                    fixture.limits.maximumTimeoutSeconds
                )
        })
        await fixture.close()
    }

    func testRuntimeToolPackSubmitsAndReadsStatusThroughContextualToolPath() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let toolPack = RuntimeJobToolPack(service: fixture.service)
        let submission = try await toolPack.handle(
            name: "bash.run",
            arguments: [
                "script": "printf 'tool-path'",
                "cwd": fixture.projectRoot.path,
                "timeout_sec": 5,
                "replay_class": RuntimeReplayClass.readOnly.rawValue,
            ],
            context: fixture.context
        )
        XCTAssertEqual(submission?.ok, true)
        guard let jobText = submission?.payload["job_id"] as? String,
              let jobID = UUID(uuidString: jobText) else {
            XCTFail("runtime tool path did not return a job identifier")
            await fixture.close()
            return
        }
        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .completed)
        let status = try await toolPack.handle(
            name: "job.status",
            arguments: ["job_id": jobText],
            context: fixture.context
        )
        XCTAssertEqual(status?.payload["state"] as? String, RuntimeJobState.completed.rawValue)
        await fixture.close()
    }

    func testSynchronousRuntimeBridgePreservesDeadlineWhenCancelledTaskStops() throws {
        let cancellation = ToolCallCancellation(timeoutSeconds: 0.05)
        do {
            let _: String = try RuntimeJobSynchronousToolPack.wait(
                timeoutSeconds: 1,
                cancellation: cancellation,
                committedResultWins: true
            ) {
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
            XCTFail("expired runtime deadline unexpectedly returned a value")
        } catch {
            XCTAssertTrue(
                error is ToolCallDeadlineExceeded,
                "task cancellation replaced the deadline error: \(error)"
            )
        }
    }

    func testSynchronousRuntimeBridgeCommittedReceiptWinsCancelledChildTerminal() throws {
        let cancellation = ToolCallCancellation()
        let receipt = RuntimeBlockingResult<String>()
        let value: String = try RuntimeJobSynchronousToolPack.wait(
            timeoutSeconds: 1,
            cancellation: cancellation,
            committedResultWins: true,
            committedReceipt: receipt
        ) {
            receipt.store(.success("committed-after-cancellation"))
            cancellation.cancel()
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        XCTAssertEqual(value, "committed-after-cancellation")
    }

    func testSynchronousRuntimeBridgeCommittedReceiptWinsDeadlineChildTerminal() throws {
        let receipt = RuntimeBlockingResult<String>()
        let value: String = try RuntimeJobSynchronousToolPack.wait(
            timeoutSeconds: 0.1,
            cancellation: nil,
            committedResultWins: true,
            committedReceipt: receipt
        ) {
            receipt.store(.success("committed-before-deadline"))
            while !Task.isCancelled {
                await Task.yield()
            }
            throw ToolCallDeadlineExceeded()
        }
        XCTAssertEqual(value, "committed-before-deadline")
    }

    func testSynchronousRuntimeBridgeWithoutReceiptPreservesCancellation() throws {
        let cancellation = ToolCallCancellation()
        do {
            let _: String = try RuntimeJobSynchronousToolPack.wait(
                timeoutSeconds: 1,
                cancellation: cancellation,
                committedResultWins: true
            ) {
                cancellation.cancel()
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
            XCTFail("cancelled runtime bridge unexpectedly returned a value")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
    }

    func testRuntimeSubmissionReceiptIsPublishedAtCommitBeforeRepositoryReturns() async throws {
        let gate = RepositoryCommitGate(expectedKind: .submission)
        let fixture = try await Fixture.make(afterMutationCommitObserver: { kind in
            gate.observe(kind)
        })
        defer {
            gate.release()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let receipt = RuntimeBlockingResult<ToolResult>()
        let toolPack = RuntimeJobToolPack(
            service: fixture.service,
            durableResultObserver: { value in
                receipt.store(.success(value))
            }
        )
        let cancellation = ToolCallCancellation()
        let bridgeResult = RuntimeBlockingResult<ToolResult>()
        let bridgeFinished = DispatchSemaphore(value: 0)
        let context = fixture.context
        let cwd = fixture.projectRoot.path

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value: ToolResult = try RuntimeJobSynchronousToolPack.wait(
                    timeoutSeconds: 0.1,
                    cancellation: cancellation,
                    committedResultWins: true,
                    committedReceipt: receipt
                ) {
                    try await toolPack.handle(
                        name: "bash.run",
                        arguments: [
                            "script": "printf 'submission-receipt'",
                            "cwd": cwd,
                            "timeout_sec": 5,
                            "replay_class": RuntimeReplayClass.readOnly.rawValue,
                        ],
                        context: context
                    ) ?? .failure(code: "missing_result", message: "runtime tool returned no result")
                }
                bridgeResult.store(.success(value))
            } catch {
                bridgeResult.store(.failure(error))
            }
            bridgeFinished.signal()
        }

        XCTAssertEqual(gate.waitUntilCommitted(), .success)
        cancellation.cancel()
        XCTAssertEqual(
            bridgeFinished.wait(timeout: .now() + 1),
            .success,
            "submission bridge did not reconcile its COMMIT receipt while the actor was gated"
        )
        let result = try XCTUnwrap(bridgeResult.take()).get()
        XCTAssertTrue(result.ok)
        let jobID = try XCTUnwrap(
            (result.payload["job_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        XCTAssertEqual(result.payload["state"] as? String, RuntimeJobState.queued.rawValue)

        gate.release()
        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .completed)
        await fixture.close()
    }

    func testRuntimeCancellationReceiptIsPublishedAtCommitBeforeRepositoryReturns() async throws {
        let gate = RepositoryCommitGate(expectedKind: .cancellation)
        let fixture = try await Fixture.make(afterMutationCommitObserver: { kind in
            gate.observe(kind)
        })
        defer {
            gate.release()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let ready = fixture.projectRoot.appendingPathComponent("cancel-receipt-ready")
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: ": > cancel-receipt-ready; while :; do sleep 1; done",
                timeout: 30
            )
        )
        guard await Self.waitForFile(ready) else {
            await fixture.close()
            XCTFail("runtime cancellation receipt fixture did not start")
            return
        }

        let receipt = RuntimeBlockingResult<ToolResult>()
        let toolPack = RuntimeJobToolPack(
            service: fixture.service,
            durableResultObserver: { value in
                receipt.store(.success(value))
            }
        )
        let cancellation = ToolCallCancellation()
        let bridgeResult = RuntimeBlockingResult<ToolResult>()
        let bridgeFinished = DispatchSemaphore(value: 0)
        let context = fixture.context

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value: ToolResult = try RuntimeJobSynchronousToolPack.wait(
                    timeoutSeconds: 0.1,
                    cancellation: cancellation,
                    committedResultWins: true,
                    committedReceipt: receipt
                ) {
                    try await toolPack.handle(
                        name: "job.cancel",
                        arguments: ["job_id": jobID.uuidString.lowercased()],
                        context: context
                    ) ?? .failure(code: "missing_result", message: "runtime tool returned no result")
                }
                bridgeResult.store(.success(value))
            } catch {
                bridgeResult.store(.failure(error))
            }
            bridgeFinished.signal()
        }

        XCTAssertEqual(gate.waitUntilCommitted(), .success)
        cancellation.cancel()
        XCTAssertEqual(
            bridgeFinished.wait(timeout: .now() + 1),
            .success,
            "cancellation bridge did not reconcile its COMMIT receipt while the actor was gated"
        )
        let result = try XCTUnwrap(bridgeResult.take()).get()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload["job_id"] as? String, jobID.uuidString.lowercased())
        XCTAssertTrue(
            result.payload["state"] as? String == RuntimeJobState.cancelling.rawValue
                || result.payload["state"] as? String == RuntimeJobState.cancelled.rawValue
        )

        gate.release()
        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .cancelled)
        await fixture.close()
    }

    func testCancelledRuntimeCreateRollsBackAfterDatabaseAdmission() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtimeDatabaseURL = await fixture.runtimeRepository.databaseURL
        var locker: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                runtimeDatabaseURL.path,
                &locker,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let opened = try XCTUnwrap(locker)
        defer {
            sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
            sqlite3_close(opened)
        }
        XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let jobID = UUID()
        let idempotencyKey = "cancelled-runtime-create-\(jobID.uuidString.lowercased())"
        let request = fixture.request(
            kind: .bash,
            profile: .bashNoProfile,
            script: "printf never-created",
            timeout: 5,
            idempotencyKey: idempotencyKey
        )
        let create = Task {
            try await fixture.runtimeRepository.createJob(
                jobID: jobID,
                request: request,
                commandSummary: "cancelled runtime create",
                timeoutSeconds: 5,
                requestArtifactRelativePath: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        create.cancel()
        sqlite3_exec(opened, "COMMIT;", nil, nil, nil)

        do {
            _ = try await create.value
            XCTFail("cancelled runtime create unexpectedly committed")
        } catch is CancellationError {
            // Expected: cancellation is checked after actor/database admission.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let stored = try await fixture.runtimeRepository.existingJob(
            projectID: fixture.projectID,
            generation: fixture.context.projectGeneration,
            idempotencyKey: idempotencyKey
        )
        XCTAssertNil(stored)
        await fixture.close()
    }

    func testRuntimeJobCancelReturnsCommittedStatusAfterCallerCancellation() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ready = fixture.projectRoot.appendingPathComponent("job-cancel-commit-ready")
        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: ": > job-cancel-commit-ready; while :; do sleep 1; done",
                timeout: 30
            )
        )
        let didStart = await Self.waitForFile(ready)
        guard didStart else {
            await fixture.close()
            XCTFail("runtime cancellation fixture did not start")
            return
        }

        let gate = PostCancellationCommitGate()
        let toolPack = RuntimeJobToolPack(
            service: fixture.service,
            postCancellationCommit: {
                await gate.pause()
            }
        )
        let invocation = Task {
            try await toolPack.handle(
                name: "job.cancel",
                arguments: ["job_id": jobID.uuidString.lowercased()],
                context: fixture.context
            )
        }
        await gate.waitUntilPaused()
        let committed = try await fixture.runtimeRepository.job(jobID)
        XCTAssertTrue(
            committed?.state == .cancelling || committed?.state == .cancelled,
            "job cancellation was not durable before the caller was cancelled"
        )

        invocation.cancel()
        await gate.release()
        let result = try await invocation.value
        XCTAssertEqual(result?.ok, true)
        XCTAssertTrue(
            result?.payload["state"] as? String == RuntimeJobState.cancelling.rawValue
                || result?.payload["state"] as? String == RuntimeJobState.cancelled.rawValue
        )

        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .cancelled)
        await fixture.close()
    }

    func testBootstrapDefaultRouterRegistersRuntimeSurfaceExactlyOnceAndMCPDescriptors() throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-surface")
        defer { fixture.close() }

        let expectedNames = RuntimeJobToolPack.names + ["shell_exec"]
        XCTAssertEqual(Set(fixture.app.tools.toolNames).count, fixture.app.tools.toolNames.count)
        for name in expectedNames {
            XCTAssertEqual(
                fixture.app.tools.toolNames.filter { $0 == name }.count,
                1,
                "default ToolRouter must register \(name) exactly once"
            )
        }

        let server = MCPServer(app: fixture.app, clientID: fixture.clientID)
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
        for name in expectedNames {
            let matches = descriptors.filter { $0["name"] as? String == name }
            XCTAssertEqual(matches.count, 1, "MCP tools/list must advertise \(name) exactly once")
            let descriptor = try XCTUnwrap(matches.first)
            let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            if name != "shell_exec" {
                XCTAssertEqual(
                    descriptor["description"] as? String,
                    RuntimeJobToolPack.description(for: name)
                )
                XCTAssertNotNil(RuntimeJobToolPack.schema(for: name))
            }
        }

        let shell = try XCTUnwrap(descriptors.first { $0["name"] as? String == "shell_exec" })
        let shellSchema = try XCTUnwrap(shell["inputSchema"] as? [String: Any])
        let shellProperties = try XCTUnwrap(shellSchema["properties"] as? [String: Any])
        let timeout = try XCTUnwrap(shellProperties["timeout_sec"] as? [String: Any])
        XCTAssertEqual(timeout["type"] as? String, "number")
        XCTAssertEqual(Set(timeout.keys), ["type"])
        XCTAssertEqual(shellSchema["required"] as? [String], ["command"])
    }

    func testBootstrapRouterLegacyShellExecUsesBoundProjectAndCompatibilityContract() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-legacy-shell")
        defer { fixture.close() }
        let context = try fixture.bindProject()
        let command = "shopt -q login_shell || exit 97; printf 'legacy-router:%s' \"$0\""

        let result = try fixture.app.tools.call(
            name: "shell_exec",
            arguments: [
                "command": command,
                "cwd": fixture.projectRoot.path,
                "timeout_sec": 999,
            ],
            clientID: fixture.clientID
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertFalse(result.isError)
        XCTAssertEqual((result.payload["exit_code"] as? NSNumber)?.int32Value, 0)
        XCTAssertTrue((result.payload["stdout"] as? String)?.contains("legacy-router:/bin/bash") == true)
        XCTAssertEqual(result.payload["stderr"] as? String, "")
        XCTAssertEqual(result.payload["timed_out"] as? Bool, false)
        XCTAssertEqual(result.payload["stdout_truncated"] as? Bool, false)
        XCTAssertEqual(result.payload["stderr_truncated"] as? Bool, false)
        XCTAssertEqual(result.payload["command"] as? String, command)
        XCTAssertEqual(result.payload["cwd"] as? String, fixture.projectRoot.path)
        for key in [
            "ok", "exit_code", "stdout", "stderr", "timed_out",
            "stdout_truncated", "stderr_truncated", "command", "cwd",
        ] {
            XCTAssertNotNil(result.payload[key], "missing legacy shell response key \(key)")
        }

        let jobs = try await fixture.app.runtimeJobs.repository.list(context: context)
        let job = try XCTUnwrap(jobs.first { $0.executionProfile == .legacyBashLogin })
        XCTAssertEqual(job.runtimeKind, .bash)
        XCTAssertEqual(job.timeoutSeconds, LegacyShellJobAdapter.maximumTimeoutSeconds)
        XCTAssertEqual(job.state, .completed)
    }

    func testBootstrapRouterRunsDurableShellJobAndReadsBoundedOutput() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-durable-shell")
        defer { fixture.close() }
        _ = try fixture.bindProject()

        let capabilities = try fixture.app.tools.call(
            name: "runtime.capabilities",
            arguments: [:],
            clientID: fixture.clientID
        )
        XCTAssertTrue(capabilities.ok, "\(capabilities.payload)")
        XCTAssertEqual(capabilities.payload["shell_available"] as? Bool, true)
        XCTAssertEqual(
            (capabilities.payload["direct_process"] as? [String: Any])?["available"] as? Bool,
            true
        )

        let expectedOutput = "runtime-router-output-abcdefghijklmnopqrstuvwxyz"
        let submission = try fixture.app.tools.call(
            name: "shell.run",
            arguments: [
                "script": "printf '\(expectedOutput)'",
                "cwd": fixture.projectRoot.path,
                "timeout_sec": 5,
                "replay_class": RuntimeReplayClass.readOnly.rawValue,
            ],
            clientID: fixture.clientID
        )
        XCTAssertTrue(submission.ok, "\(submission.payload)")
        let jobID = try XCTUnwrap(submission.payload["job_id"] as? String)

        var terminalStatus: ToolResult?
        for _ in 0..<40 {
            let status = try fixture.app.tools.call(
                name: "job.status",
                arguments: ["job_id": jobID],
                clientID: fixture.clientID
            )
            XCTAssertTrue(status.ok, "\(status.payload)")
            if status.payload["state"] as? String == RuntimeJobState.completed.rawValue {
                terminalStatus = status
                break
            }
            _ = try fixture.app.tools.call(
                name: "job.list",
                arguments: ["limit": 1],
                clientID: fixture.clientID
            )
            try await Task.sleep(for: .milliseconds(25))
        }
        let terminal = try XCTUnwrap(terminalStatus, "runtime job did not complete within the bounded poll window")
        XCTAssertEqual(terminal.payload["execution_profile"] as? String, RuntimeExecutionProfile.zshNoProfile.rawValue)
        XCTAssertEqual((terminal.payload["exit_code"] as? NSNumber)?.int32Value, 0)

        let first = try fixture.app.tools.call(
            name: "job.read_output",
            arguments: ["job_id": jobID, "stream": "stdout", "offset": 0, "limit": 8],
            clientID: fixture.clientID
        )
        XCTAssertTrue(first.ok, "\(first.payload)")
        let firstText = try XCTUnwrap(first.payload["data"] as? String)
        XCTAssertLessThanOrEqual(firstText.utf8.count, 8)
        XCTAssertEqual(firstText, String(expectedOutput.prefix(8)))
        XCTAssertEqual(first.payload["eof"] as? Bool, false)
        let nextOffset = try XCTUnwrap((first.payload["next_offset"] as? NSNumber)?.uint64Value)

        let remainder = try fixture.app.tools.call(
            name: "job.read_output",
            arguments: [
                "job_id": jobID,
                "stream": "stdout",
                "offset": nextOffset,
                "limit": 64,
            ],
            clientID: fixture.clientID
        )
        XCTAssertTrue(remainder.ok, "\(remainder.payload)")
        XCTAssertEqual(firstText + (remainder.payload["data"] as? String ?? ""), expectedOutput)
        XCTAssertEqual(remainder.payload["eof"] as? Bool, true)
        XCTAssertEqual(
            (remainder.payload["observed_bytes"] as? NSNumber)?.intValue,
            expectedOutput.utf8.count
        )
    }

    private static func createRuntimeSchemaV2(
        at databaseURL: URL,
        jobID: UUID,
        projectID: ProjectID
    ) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not create schema-v2 fixture")
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE runtime_job_schema_version (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            version INTEGER NOT NULL CHECK(version>=1),
            applied_at TEXT NOT NULL
        );
        INSERT INTO runtime_job_schema_version(singleton,version,applied_at)
        VALUES(1,2,'2026-08-26T00:00:00.000Z');
        CREATE TABLE execution_jobs (
            job_id TEXT PRIMARY KEY,
            run_id TEXT,
            project_id TEXT NOT NULL,
            project_generation INTEGER NOT NULL CHECK(project_generation>=1),
            runtime_kind TEXT NOT NULL,
            execution_profile TEXT NOT NULL,
            replay_class TEXT NOT NULL,
            idempotency_key TEXT,
            state TEXT NOT NULL,
            canonical_cwd TEXT NOT NULL,
            command_summary TEXT NOT NULL,
            timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds>0),
            exit_code INTEGER,
            stdout_inline TEXT,
            stderr_inline TEXT,
            output_artifact_id TEXT,
            output_bytes INTEGER NOT NULL DEFAULT 0 CHECK(output_bytes>=0),
            process_identifier INTEGER,
            process_group_identifier INTEGER,
            created_at TEXT NOT NULL,
            started_at TEXT,
            completed_at TEXT,
            updated_at TEXT NOT NULL
        );
        INSERT INTO execution_jobs(
            job_id,run_id,project_id,project_generation,runtime_kind,execution_profile,
            replay_class,idempotency_key,state,canonical_cwd,command_summary,timeout_seconds,
            exit_code,stdout_inline,stderr_inline,output_artifact_id,output_bytes,
            process_identifier,process_group_identifier,created_at,started_at,completed_at,updated_at
        ) VALUES(
            '\(jobID.uuidString.lowercased())',NULL,'\(projectID.description)',1,'bash','bash_no_profile',
            'read_only',NULL,'completed','/legacy/runtime-project','legacy v2 completed job',30,
            0,'legacy output','',NULL,14,NULL,NULL,'2026-08-26T00:00:00.000Z',
            '2026-08-26T00:00:00.100Z','2026-08-26T00:00:01.000Z','2026-08-26T00:00:01.000Z'
        );
        """
        var message: UnsafeMutablePointer<CChar>?
        let executed = sqlite3_exec(database, sql, nil, nil, &message)
        guard executed == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite error \(executed)"
            sqlite3_free(message)
            throw RuntimeJobError.storageFailure(detail)
        }
    }

    private struct SQLiteFamilySnapshot: Equatable {
        let database: Data?
        let writeAheadLog: Data?
        let sharedMemory: Data?
        let rollbackJournal: Data?
    }

    private static func sqliteFamilySnapshot(at databaseURL: URL) throws -> SQLiteFamilySnapshot {
        func dataIfPresent(_ url: URL) throws -> Data? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        return try SQLiteFamilySnapshot(
            database: dataIfPresent(databaseURL),
            writeAheadLog: dataIfPresent(URL(fileURLWithPath: databaseURL.path + "-wal")),
            sharedMemory: dataIfPresent(URL(fileURLWithPath: databaseURL.path + "-shm")),
            rollbackJournal: dataIfPresent(URL(fileURLWithPath: databaseURL.path + "-journal"))
        )
    }

    private static func openSQLiteFixture(at databaseURL: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not open control-plane fixture")
        }
        return database
    }

    private static func executeSQLiteFixture(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let executed = sqlite3_exec(database, sql, nil, nil, &message)
        guard executed == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite error \(executed)"
            sqlite3_free(message)
            throw RuntimeJobError.storageFailure(detail)
        }
    }

    private static func createUnversionedRuntimeFixture(at databaseURL: URL) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not create unversioned runtime fixture")
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let executed = sqlite3_exec(
            database,
            """
            PRAGMA journal_mode=DELETE;
            CREATE TABLE foreign_records(id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
            INSERT INTO foreign_records(id,payload) VALUES(1,'must remain byte-for-byte intact');
            """,
            nil,
            nil,
            &message
        )
        guard executed == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite error \(executed)"
            sqlite3_free(message)
            throw RuntimeJobError.storageFailure(detail)
        }
    }

    private static func sqliteColumnNames(databaseURL: URL, table: String) throws -> Set<String> {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not open SQLite fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure("could not inspect SQLite columns")
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { continue }
            names.insert(String(cString: value))
        }
        return names
    }

    private static func sqliteCount(
        databaseURL: URL,
        sql: String,
        textBinding: String? = nil,
        textBindings: [String] = []
    ) throws -> Int {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not open SQLite fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure("could not prepare SQLite count")
        }
        defer { sqlite3_finalize(statement) }
        let bindings = textBindings.isEmpty ? textBinding.map { [$0] } ?? [] : textBindings
        if !bindings.isEmpty {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, binding) in bindings.enumerated() {
                guard sqlite3_bind_text(
                    statement,
                    Int32(offset + 1),
                    binding,
                    -1,
                    transient
                ) == SQLITE_OK else {
                    throw RuntimeJobError.storageFailure("could not bind SQLite count")
                }
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RuntimeJobError.storageFailure("could not read SQLite count")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func sqliteText(databaseURL: URL, sql: String) throws -> String? {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not open SQLite fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure("could not prepare SQLite text query")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RuntimeJobError.storageFailure("could not read SQLite text")
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private static let testLimits = RuntimeJobLimits(
        maximumConcurrentJobs: 2,
        maximumCPUHeavyJobs: 1,
        maximumQueuedJobs: 8,
        maximumInlineOutputBytes: 1_024,
        maximumArtifactBytesPerJob: 8 * 1_024,
        maximumScriptBytes: 256 * 1_024,
        maximumArguments: 64,
        maximumArgumentBytes: 16 * 1_024,
        maximumTimeoutSeconds: 60,
        terminationGraceMilliseconds: 100,
        forcedTerminationGraceMilliseconds: 1_000
    )

    private static func readPID(_ url: URL) throws -> Int32 {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(text), pid > 1 else {
            throw RuntimeJobError.invalidRequest("fixture did not write a valid descendant PID")
        }
        return pid
    }

    private static func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private static func waitUntilProcessIsGone(_ pid: Int32) async -> Bool {
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    private struct LoopbackListener {
        let descriptor: Int32
        let port: UInt16
    }

    private struct UnixListener {
        let descriptor: Int32
        let path: String
    }

    private static func makeUnixListener(at url: URL) throws -> UnixListener {
        let path = url.path
        let encodedPath = Array(path.utf8) + [0]
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard encodedPath.count <= capacity else {
            throw NSError(domain: "runtime-unix-network-test", code: Int(ENAMETOOLONG))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: encodedPath)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "runtime-unix-network-test", code: Int(errno))
        }
        do {
            _ = Darwin.unlink(path)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
                throw NSError(domain: "runtime-unix-network-test", code: Int(errno))
            }
            return UnixListener(descriptor: descriptor, path: path)
        } catch {
            Darwin.close(descriptor)
            _ = Darwin.unlink(path)
            throw error
        }
    }

    private static func makeLoopbackListener() throws -> LoopbackListener {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "runtime-network-test", code: Int(errno))
        }
        do {
            var reuse: Int32 = 1
            guard Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw NSError(domain: "runtime-network-test", code: Int(errno))
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0, Darwin.listen(descriptor, 4) == 0 else {
                throw NSError(domain: "runtime-network-test", code: Int(errno))
            }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            guard nameResult == 0 else {
                throw NSError(domain: "runtime-network-test", code: Int(errno))
            }
            return LoopbackListener(
                descriptor: descriptor,
                port: UInt16(bigEndian: bound.sin_port)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private final class Fixture {
        let root: URL
        let projectRoot: URL
        let projectID: ProjectID
        let context: ToolInvocationContext
        let controlRepository: ProjectControlPlaneRepository
        let runtimeRepository: RuntimeJobRepository
        let service: ExecutionJobService
        let limits: RuntimeJobLimits

        init(
            root: URL,
            projectRoot: URL,
            projectID: ProjectID,
            context: ToolInvocationContext,
            controlRepository: ProjectControlPlaneRepository,
            runtimeRepository: RuntimeJobRepository,
            service: ExecutionJobService,
            limits: RuntimeJobLimits
        ) {
            self.root = root
            self.projectRoot = projectRoot
            self.projectID = projectID
            self.context = context
            self.controlRepository = controlRepository
            self.runtimeRepository = runtimeRepository
            self.service = service
            self.limits = limits
        }

        static func make(
            limits: RuntimeJobLimits = testLimits,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            networkAllowed: Bool = false,
            readOnlyProject: Bool = false,
            launchObserver: any RuntimeJobLaunchObserving = NoopRuntimeJobLaunchObserver(),
            terminalPersistenceHook: any RuntimeJobTerminalPersistenceHook =
                NoopRuntimeJobTerminalPersistenceHook(),
            recoveredProcessController: (any RuntimeRecoveredProcessControlling)? = nil,
            afterMutationCommitObserver: (@Sendable (RuntimeJobCommitKind) -> Void)? = nil
        ) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-runtime-tests-\(UUID().uuidString)", isDirectory: true)
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let database = root.appendingPathComponent("control-plane.sqlite")
            let control = try ProjectControlPlaneRepository(databaseURL: database)
            let projectID = ProjectID()
            _ = try await control.registerProject(
                projectID: projectID,
                displayName: "Runtime Fixture",
                canonicalRoot: projectRoot
            )
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "runtime-test-client")
            let scope = ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                writableRoots: readOnlyProject ? [] : [projectRoot],
                allowedTools: Set(RuntimeJobToolPack.names).union(["shell_exec"]),
                networkAllowed: networkAllowed,
                maximumInlineOutputBytes: limits.maximumInlineOutputBytes
            )
            _ = try await control.bind(
                owner: owner,
                projectID: projectID,
                generation: .initial,
                authorizationScope: scope
            )
            let context = try await control.invocationContext(for: owner)
            let runtime = try RuntimeJobRepository(
                databaseURL: database,
                beforeMigrationCommitObserver: nil,
                afterMutationCommitObserver: afterMutationCommitObserver
            )
            let service = try ExecutionJobService(
                repository: runtime,
                contextValidator: ProjectControlPlaneRuntimeJobContextValidator(repository: control),
                artifactRoot: artifacts,
                limits: limits,
                environment: environment,
                launchObserver: launchObserver,
                terminalPersistenceHook: terminalPersistenceHook
            )
            if let recoveredProcessController {
                try await service.setRecoveredProcessController(recoveredProcessController)
            }
            try await service.start()
            return Fixture(
                root: root,
                projectRoot: projectRoot,
                projectID: projectID,
                context: context,
                controlRepository: control,
                runtimeRepository: runtime,
                service: service,
                limits: limits
            )
        }

        func request(
            kind: RuntimeKind,
            profile: RuntimeExecutionProfile,
            script: String,
            timeout: Int,
            context requestedContext: ToolInvocationContext? = nil,
            replayClass: RuntimeReplayClass = .readOnly,
            idempotencyKey: String? = nil
        ) -> RuntimeJobRequest {
            let requestContext = requestedContext ?? context
            return RuntimeJobRequest(
                kind: kind,
                profile: profile,
                context: requestContext,
                script: script,
                canonicalWorkingDirectory: projectRoot,
                timeout: .seconds(timeout),
                maximumInlineOutputBytes: limits.maximumInlineOutputBytes,
                replayClass: replayClass,
                idempotencyKey: idempotencyKey
            )
        }

        func autonomousRunContext(
            mission: String
        ) async throws -> (runID: RunID, context: ToolInvocationContext) {
            let request = AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: context.projectGeneration,
                mission: mission,
                providerID: "runtime-test-provider",
                modelKey: "runtime-test-model",
                specification: AutonomousRunSpecification(
                    allowedTools: RuntimeJobToolPack.names,
                    completionGates: ["runtime-job-release"]
                ),
                authorizationScope: context.authorizationScope
            )
            let run = try await controlRepository.createAutonomousRun(request)
            let owner = ProjectBindingOwner(
                kind: .autonomousRun,
                id: run.runID.description
            )
            return (
                run.runID,
                try await controlRepository.invocationContext(for: owner)
            )
        }

        func waitForState(
            _ jobID: UUID,
            expected: RuntimeJobState,
            context requestedContext: ToolInvocationContext? = nil
        ) async -> Bool {
            let statusContext = requestedContext ?? context
            for _ in 0..<200 {
                if (try? await service.status(jobID: jobID, context: statusContext).state) == expected {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func waitForRepositoryState(_ jobID: UUID, expected: RuntimeJobState) async -> Bool {
            for _ in 0..<500 {
                if (try? await runtimeRepository.job(jobID)?.state) == expected {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func close() async {
            await service.shutdown()
            await runtimeRepository.close()
            await controlRepository.close()
        }
    }

    private final class ProductionFixture {
        let root: URL
        let projectRoot: URL
        let app: ForgeApp
        let clientID: ClientID

        private init(root: URL, projectRoot: URL, app: ForgeApp, clientID: ClientID) {
            self.root = root
            self.projectRoot = projectRoot
            self.app = app
            self.clientID = clientID
        }

        static func make(clientName: String) throws -> ProductionFixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-runtime-product-\(UUID().uuidString)", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let project = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            do {
                return try ProductionFixture(
                    root: root,
                    projectRoot: project,
                    app: ForgeApp.bootstrap(home: home),
                    clientID: ClientID(clientName)
                )
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func bindProject() throws -> ToolInvocationContext {
            let initialized = try app.tools.call(
                name: "project_memory.initialize",
                arguments: ["project_path": projectRoot.path],
                clientID: clientID
            )
            guard initialized.ok else {
                throw RuntimeJobError.invalidRequest("project binding failed: \(initialized.payload)")
            }
            return try app.projectContexts.invocationContext(for: clientID)
        }

        func close() {
            app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor LaunchGate: RuntimeJobLaunchObserving {
        private var didSpawn = false
        private var released = false
        private var spawnWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func processDidSpawn(jobID: UUID, processIdentifier: Int32) async {
            didSpawn = true
            let waiters = spawnWaiters
            spawnWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitForSpawn() async {
            if didSpawn { return }
            await withCheckedContinuation { continuation in
                spawnWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private actor RecoveredSignalProbe: RuntimeRecoveredProcessControlling {
        private let result: RuntimeRecoveredProcessSignalResult
        private var observedSignals: [Int32] = []

        init(result: RuntimeRecoveredProcessSignalResult) {
            self.result = result
        }

        func signalProcessGroup(
            _ signal: Int32,
            expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            _ = expectedIdentity
            observedSignals.append(signal)
            return result
        }

        func signals() -> [Int32] { observedSignals }
    }

    private actor SwitchableRecoveredProcessController: RuntimeRecoveredProcessControlling {
        private var failing: Bool
        private let controller = DarwinRuntimeRecoveredProcessController()

        init(failing: Bool) {
            self.failing = failing
        }

        func signalProcessGroup(
            _ signal: Int32,
            expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            if failing, signal != 0 { return .signalFailed(EPERM) }
            return await controller.signalProcessGroup(
                signal,
                expectedIdentity: expectedIdentity
            )
        }

        func setFailing(_ failing: Bool) {
            self.failing = failing
        }
    }

    private actor TransientIdentityUnavailableRecoveredProcessController:
        RuntimeRecoveredProcessControlling {
        private var observedSignals: [Int32] = []
        private var livenessProbeCount = 0

        func signalProcessGroup(
            _ signal: Int32,
            expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            _ = expectedIdentity
            observedSignals.append(signal)
            switch signal {
            case SIGTERM:
                return .signaled
            case 0:
                livenessProbeCount += 1
                return livenessProbeCount == 1 ? .identityUnavailable : .processMissing
            default:
                return .identityUnavailable
            }
        }

        func signals() -> [Int32] { observedSignals }
    }

    private actor ForcedTransientIdentityUnavailableRecoveredProcessController:
        RuntimeRecoveredProcessControlling {
        private var observedSignals: [Int32] = []
        private var killAttemptCount = 0

        func signalProcessGroup(
            _ signal: Int32,
            expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            _ = expectedIdentity
            observedSignals.append(signal)
            switch signal {
            case SIGTERM:
                return .signaled
            case 0:
                return .identityUnavailable
            case SIGKILL:
                killAttemptCount += 1
                return killAttemptCount == 1 ? .identityUnavailable : .processMissing
            default:
                return .signalFailed(EINVAL)
            }
        }

        func signals() -> [Int32] { observedSignals }
    }

    private actor TerminalPersistenceGate: RuntimeJobTerminalPersistenceHook {
        private var persistenceAllowed = false

        func beforeTerminalPersistence(jobID: UUID) throws {
            guard persistenceAllowed else {
                throw RuntimeJobError.storageFailure("injected transient terminal persistence failure")
            }
        }

        func allowPersistence() {
            persistenceAllowed = true
        }
    }
}

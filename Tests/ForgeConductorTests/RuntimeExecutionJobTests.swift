// RuntimeExecutionJobTests.swift
// Focused lifecycle, output-bound, capability, and generation-fence proof for durable jobs.

import Darwin
import Security
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


    func testRunningOutputSpoolSnapshotsDoNotFinalizeOrChangeProducerHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spool = try RuntimeOutputSpool(
            jobID: UUID(), projectID: ProjectID(), generation: .initial, artifactRoot: root,
            maximumInlineBytes: 8, maximumArtifactBytes: 32
        )
        defer { spool.discard(); try? FileManager.default.removeItem(at: root) }
        let empty = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: 0, limit: 2, jobState: .queued))
        XCTAssertTrue(empty.isSnapshot)
        XCTAssertEqual(empty.jobState, .queued)
        XCTAssertEqual(empty.data, Data())
        XCTAssertEqual(empty.sha256, JSONSupport.sha256Hex(Data()))
        XCTAssertTrue(empty.eof)
        XCTAssertNil(empty.producerEndReason)
        let first = Data("A🦅Z".utf8)
        spool.append(first, stream: .stdout)
        let page = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: 0, limit: 2, jobState: .running))
        XCTAssertEqual(page.data, first.prefix(2))
        XCTAssertEqual(page.nextOffset, 2)
        XCTAssertEqual(page.sha256, JSONSupport.sha256Hex(first))
        XCTAssertFalse(page.eof)
        let initialEnd = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: 2, limit: 20, jobState: .running))
        XCTAssertTrue(initialEnd.eof)
        let second = Data([0xff, 0xfe])
        spool.append(second, stream: .stdout)
        let afterPageEnd = try XCTUnwrap(spool.snapshot(
            stream: .stdout, offset: initialEnd.nextOffset, limit: 20, jobState: .cancelling
        ))
        XCTAssertEqual(afterPageEnd.data, second)
        XCTAssertEqual(afterPageEnd.jobState, .cancelling)
        XCTAssertEqual(afterPageEnd.sha256, JSONSupport.sha256Hex(first + second))
        XCTAssertEqual(afterPageEnd.totalObservedBytes, 8)
        XCTAssertNil(afterPageEnd.producerEndReason)
        spool.endProducer(stream: .stdout, reason: .eof)
        spool.endProducer(stream: .stderr, reason: .eof)
        let ended = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: .max, limit: 2, jobState: .running))
        XCTAssertTrue(ended.isSnapshot)
        XCTAssertEqual(ended.producerEndReason, .eof)
        XCTAssertTrue(ended.data.isEmpty)
        XCTAssertEqual(ended.nextOffset, 8)
        let terminal = try spool.finalize()
        let stdout = try XCTUnwrap(terminal.first { $0.stream == .stdout })
        XCTAssertEqual(stdout.sha256, JSONSupport.sha256Hex(first + second))
        XCTAssertEqual(stdout.retainedByteCount, 8)
        XCTAssertFalse(stdout.artifactTruncated)
        XCTAssertNil(try spool.snapshot(stream: .stdout, offset: 0, limit: 2, jobState: .completed))
    }

    func testRunningOutputSnapshotCancellationLeavesOwnedSpoolReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let spool = try RuntimeOutputSpool(
            jobID: UUID(), projectID: ProjectID(), generation: .initial, artifactRoot: root,
            maximumInlineBytes: 8, maximumArtifactBytes: 32
        )
        defer { spool.discard(); try? FileManager.default.removeItem(at: root) }
        spool.append(Data("still-owned".utf8), stream: .stdout)
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try spool.snapshot(stream: .stdout, offset: 0, limit: 20, jobState: .running)
        }
        do {
            _ = try await read.value
            XCTFail("A cancelled output read must throw cancellation")
        } catch is CancellationError {}
        let later = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: 0, limit: 20, jobState: .running))
        XCTAssertEqual(later.data, Data("still-owned".utf8))
        XCTAssertEqual(later.sha256, JSONSupport.sha256Hex(Data("still-owned".utf8)))
        XCTAssertTrue(later.isSnapshot)
    }

    func testRunningOutputAbsentOwnerIsRetryableOnlyBeforeTerminalPersistence() async throws {
        let fixture = try await Fixture.make()
        let gate = SharedOwnerPreparationGate()
        let publisher = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: SharedOwnerPreparationValidator(
                base: ProjectControlPlaneRuntimeJobContextValidator(repository: fixture.controlRepository),
                gate: gate),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await publisher.start()
        let submission = Task {
            try await publisher.submit(fixture.request(
                kind: .bash, profile: .bashNoProfile, script: "exit 0", timeout: 5))
        }
        addTeardownBlock {
            await gate.release()
            submission.cancel()
            _ = await submission.result
            _ = await publisher.shutdown()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        // A real publisher retains the queued intent while wiring its owner;
        // the separate reader has neither that spool nor terminal output.
        let paused = await Self.waitUntil { await gate.observedJobID() != nil }
        XCTAssertTrue(paused)
        let pausedID = await gate.observedJobID()
        let jobID = try XCTUnwrap(pausedID)
        let pack = RuntimeJobToolPack(service: fixture.service)
        let pending = try await pack.handle(name: "job.read_output", arguments: [
            "job_id": jobID.uuidString, "stream": "stdout", "offset": 0, "limit": 100
        ], context: fixture.context)
        XCTAssertEqual(pending?.ok, false)
        XCTAssertEqual(pending?.payload["code"] as? String, "runtime_output_unavailable")
        XCTAssertEqual(pending?.payload["retryable"] as? Bool, true)
        XCTAssertNil(pending?.payload["data"])
        XCTAssertNil(pending?.payload["sha256"])
        try await publisher.cancel(jobID: jobID, context: fixture.context)
        let terminal = try await pack.handle(name: "job.read_output", arguments: [
            "job_id": jobID.uuidString, "stream": "stdout", "offset": 0, "limit": 100
        ], context: fixture.context)
        XCTAssertEqual(terminal?.ok, false)
        XCTAssertEqual(terminal?.payload["code"] as? String, "runtime_output_unavailable")
        XCTAssertEqual(terminal?.payload["retryable"] as? Bool, false)
    }

    func testRunningOutputSpoolVerifiesIdentityDigestAndRetainedBounds() throws {
        for substitution in ["symlink", "replacement", "mutation", "hardlink"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let spool = try RuntimeOutputSpool(
                jobID: UUID(), projectID: ProjectID(), generation: .initial, artifactRoot: root,
                maximumInlineBytes: 4, maximumArtifactBytes: 16
            )
            defer { spool.discard(); try? FileManager.default.removeItem(at: root) }
            spool.append(Data(repeating: 0x61, count: 20), stream: .stdout)
            let before = try XCTUnwrap(spool.snapshot(stream: .stdout, offset: 0, limit: 3, jobState: .running))
            XCTAssertEqual(before.totalRetainedBytes, 12)
            XCTAssertEqual(before.totalObservedBytes, 20)
            XCTAssertTrue(before.artifactTruncated)
            XCTAssertEqual(before.data, Data(repeating: 0x61, count: 3))
            let artifact = spool.canonicalDirectory.appendingPathComponent("stdout.log")
            switch substitution {
            case "symlink":
                try FileManager.default.removeItem(at: artifact)
                let target = root.appendingPathComponent("outside-output")
                try Data(repeating: 0x61, count: 12).write(to: target)
                try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: target)
            case "replacement":
                try FileManager.default.removeItem(at: artifact)
                try Data(repeating: 0x61, count: 12).write(to: artifact)
            case "hardlink":
                try FileManager.default.linkItem(at: artifact, to: root.appendingPathComponent("extra-link"))
            default:
                let handle = try FileHandle(forWritingTo: artifact)
                try handle.write(contentsOf: Data(repeating: 0x62, count: 12))
                try handle.close()
            }
            XCTAssertThrowsError(try spool.snapshot(stream: .stdout, offset: 0, limit: 3, jobState: .running)) {
                XCTAssertEqual(($0 as? RuntimeJobError)?.code, "runtime_storage_failure", substitution)
            }
        }
    }

    func testRunningOutputZeroBytesThenArrivalPagingAndTerminalTransition() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock { await fixture.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let ready = fixture.projectRoot.appendingPathComponent("ready")
        let firstRelease = fixture.projectRoot.appendingPathComponent("first-release")
        let finish = fixture.projectRoot.appendingPathComponent("finish")
        let waitFirst = "i=0; while [ ! -e '\(firstRelease.path)' ] && [ $i -lt 1000 ]; do /bin/sleep 0.01; i=$((i+1)); done"
        let waitFinish = "i=0; while [ ! -e '\(finish.path)' ] && [ $i -lt 1000 ]; do /bin/sleep 0.01; i=$((i+1)); done"
        let jobID = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile,
            script: ": > '\(ready.path)'; \(waitFirst); printf 'A🦅Z'; printf 'first-error' >&2; \(waitFinish); printf '\\377\\376'",
            timeout: 15
        ))
        let readyReached = await Self.waitForFile(ready)
        XCTAssertTrue(readyReached)
        let empty = try await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 2, context: fixture.context)
        XCTAssertTrue(empty.isSnapshot)
        XCTAssertEqual(empty.jobState, .running)
        XCTAssertTrue(empty.data.isEmpty)
        XCTAssertTrue(empty.eof)
        XCTAssertNil(empty.producerEndReason)
        try Data().write(to: firstRelease)
        let arrived = await Self.waitUntil {
            let page = try? await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 20, context: fixture.context)
            return page?.totalRetainedBytes == 6
        }
        XCTAssertTrue(arrived)
        let pack = RuntimeJobToolPack(service: fixture.service)
        var reconstructed = Data()
        for offset: UInt64 in [0, 2, 4] {
            let result = try await pack.handle(name: "job.read_output", arguments: [
                "job_id": jobID.uuidString, "stream": "stdout", "offset": offset, "limit": 2
            ], context: fixture.context)
            let page = try XCTUnwrap(result?.payload)
            XCTAssertEqual(result?.ok, true)
            XCTAssertEqual(page["is_snapshot"] as? Bool, true)
            XCTAssertEqual(page["sha256_is_provisional"] as? Bool, true)
            XCTAssertEqual(page["producer_eof"] as? Bool, false)
            XCTAssertEqual(page["sha256"] as? String, JSONSupport.sha256Hex(Data("A🦅Z".utf8)))
            let raw: Data
            if let base64 = page["data_base64"] as? String {
                raw = try XCTUnwrap(Data(base64Encoded: base64))
            } else {
                raw = Data((try XCTUnwrap(page["data"] as? String)).utf8)
            }
            reconstructed.append(raw)
            XCTAssertEqual(page["eof"] as? Bool, offset == 4)
        }
        XCTAssertEqual(reconstructed, Data("A🦅Z".utf8))
        let stderrArrived = await Self.waitUntil {
            (try? await fixture.service.readOutput(jobID: jobID, stream: .stderr, offset: 0, limit: 20, context: fixture.context).data) == Data("first-error".utf8)
        }
        XCTAssertTrue(stderrArrived)
        try Data().write(to: finish)
        let terminal = try await fixture.service.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.exitCode, 0)
        let final = try await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 6, limit: 20, context: fixture.context)
        XCTAssertFalse(final.isSnapshot)
        XCTAssertEqual(final.jobState, .completed)
        XCTAssertEqual(final.data, Data([0xff, 0xfe]))
        XCTAssertEqual(final.sha256, JSONSupport.sha256Hex(Data("A🦅Z".utf8) + Data([0xff, 0xfe])))
        XCTAssertEqual(final.producerEndReason, .eof)
        XCTAssertFalse(final.artifactTruncated)
    }

    func testRunningOutputQueuedCancellationAndTimeoutPreserveFinalPages() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock { await fixture.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let running = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile, script: "printf 'before-cancel'; /bin/sleep 20", timeout: 30
        ))
        let firstArrived = await Self.waitUntil {
            (try? await fixture.service.readOutput(jobID: running, stream: .stdout, offset: 0, limit: 100, context: fixture.context).data) == Data("before-cancel".utf8)
        }
        XCTAssertTrue(firstArrived)
        let second = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile, script: "/bin/sleep 20", timeout: 30
        ))
        let secondRunning = await fixture.waitForState(second, expected: .running)
        XCTAssertTrue(secondRunning)
        let queued = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile, script: "printf 'must-not-launch'", timeout: 5
        ))
        let queuedPage = try await fixture.service.readOutput(jobID: queued, stream: .stdout, offset: 0, limit: 100, context: fixture.context)
        XCTAssertTrue(queuedPage.isSnapshot)
        XCTAssertEqual(queuedPage.jobState, .queued)
        XCTAssertTrue(queuedPage.data.isEmpty)
        try await fixture.service.cancel(jobID: queued, context: fixture.context)
        try await fixture.service.cancel(jobID: running, context: fixture.context)
        try await fixture.service.cancel(jobID: second, context: fixture.context)
        let cancelled = try await fixture.service.waitForTerminal(jobID: running, context: fixture.context, maximumWait: .seconds(8))
        _ = try await fixture.service.waitForTerminal(jobID: second, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(cancelled.state, .cancelled)
        let final = try await fixture.service.readOutput(jobID: running, stream: .stdout, offset: 0, limit: 100, context: fixture.context)
        XCTAssertFalse(final.isSnapshot)
        XCTAssertEqual(final.jobState, .cancelled)
        XCTAssertEqual(final.data, Data("before-cancel".utf8))
        let timed = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile, script: "printf 'before-timeout'; /bin/sleep 20", timeout: 1
        ))
        let timedArrived = await Self.waitUntil {
            (try? await fixture.service.readOutput(jobID: timed, stream: .stdout, offset: 0, limit: 100, context: fixture.context).data) == Data("before-timeout".utf8)
        }
        XCTAssertTrue(timedArrived)
        let timeout = try await fixture.service.waitForTerminal(jobID: timed, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(timeout.state, .timedOut)
        let timeoutPage = try await fixture.service.readOutput(jobID: timed, stream: .stdout, offset: 0, limit: 100, context: fixture.context)
        XCTAssertFalse(timeoutPage.isSnapshot)
        XCTAssertEqual(timeoutPage.jobState, .timedOut)
        XCTAssertEqual(timeoutPage.data, Data("before-timeout".utf8))
    }

    func testRunningOutputRejectsStaleCallerAndForeignJobBeforeSnapshot() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock { await fixture.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let jobID = try await fixture.service.submit(fixture.request(
            kind: .bash, profile: .bashNoProfile, script: "printf 'private-output'; /bin/sleep 2", timeout: 5
        ))
        let arrived = await Self.waitUntil {
            (try? await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 100, context: fixture.context).data) == Data("private-output".utf8)
        }
        XCTAssertTrue(arrived)
        let foreignRoot = fixture.root.appendingPathComponent("foreign-project")
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let foreignID = ProjectID()
        _ = try await fixture.controlRepository.registerProjectUnchecked(projectID: foreignID, displayName: "Foreign", canonicalRoot: foreignRoot)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "foreign-output-client")
        _ = try await fixture.controlRepository.bind(owner: owner, projectID: foreignID, generation: .initial, authorizationScope: ToolAuthorizationScope(canonicalRoots: [foreignRoot], writableRoots: [], allowedTools: ["job.read_output"], networkAllowed: false, maximumInlineOutputBytes: 1024))
        let foreign = try await fixture.controlRepository.invocationContext(for: owner)
        do {
            _ = try await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 100, context: foreign)
            XCTFail("A foreign project must not read an owned live spool")
        } catch {
            XCTAssertEqual((error as? RuntimeJobError)?.code, "runtime_job_scope_mismatch")
        }
        let otherRun = try await fixture.autonomousRunContext(mission: "Reject output outside this run")
        do {
            _ = try await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 100, context: otherRun.context)
            XCTFail("A run context must not read a job from another run")
        } catch {
            XCTAssertEqual((error as? RuntimeJobError)?.code, "runtime_job_scope_mismatch")
        }
        let deniedOwner = ProjectBindingOwner(kind: .mcpClient, id: "denied-output-client")
        _ = try await fixture.controlRepository.bind(owner: deniedOwner, projectID: fixture.projectID, generation: .initial,
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [fixture.projectRoot], writableRoots: [], allowedTools: ["job.status"], networkAllowed: false, maximumInlineOutputBytes: 1024))
        let deniedContext = try await fixture.controlRepository.invocationContext(for: deniedOwner)
        let denied = try await RuntimeJobToolPack(service: fixture.service).handle(name: "job.read_output",
            arguments: ["job_id": jobID.uuidString, "stream": "stdout", "limit": 100], context: deniedContext)
        XCTAssertEqual(denied?.ok, false)
        XCTAssertEqual(denied?.payload["code"] as? String, "tool_not_authorized")
        XCTAssertNil(denied?.payload["data"])
        _ = try await fixture.controlRepository.beginReset(projectID: fixture.projectID, expectedGeneration: .initial)
        _ = try await fixture.controlRepository.completeReset(projectID: fixture.projectID, expectedGeneration: .initial)
        do {
            _ = try await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 100, context: fixture.context)
            XCTFail("A stale context must not read an owned live spool")
        } catch {
            XCTAssertEqual((error as? ProjectContextError)?.code, "stale_project_generation")
        }
    }

    func testRunningOutputInvalidBytesFitCompleteDurableResultBudget() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock { await fixture.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let finish = fixture.projectRoot.appendingPathComponent("finish-budget")
        let script = "printf '\(String(repeating: "\\377", count: 4096))'; i=0; while [ ! -e '\(finish.path)' ] && [ $i -lt 1000 ]; do /bin/sleep 0.01; i=$((i+1)); done"
        let jobID = try await fixture.service.submit(fixture.request(kind: .bash, profile: .bashNoProfile, script: script, timeout: 15))
        let arrived = await Self.waitUntil {
            (try? await fixture.service.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 4096, context: fixture.context).totalRetainedBytes) == 4096
        }
        XCTAssertTrue(arrived)
        let pack = RuntimeJobToolPack(service: fixture.service)
        var offset: UInt64 = 0
        var reconstructed = Data()
        for _ in 0..<128 {
            let handled = try await pack.handle(name: "job.read_output", arguments: ["job_id": jobID.uuidString, "stream": "stdout", "offset": offset, "limit": 4096], context: fixture.context)
            let result = try XCTUnwrap(handled)
            XCTAssertTrue(result.ok)
            let encoded = try JSONSupport.canonicalJSON(["ok": result.ok, "is_error": result.isError, "payload": result.payload])
            XCTAssertLessThanOrEqual(encoded.utf8.count, fixture.context.authorizationScope.maximumInlineOutputBytes)
            let bytes = try XCTUnwrap((result.payload["data_base64"] as? String).flatMap { Data(base64Encoded: $0) })
            let next = try XCTUnwrap((result.payload["next_offset"] as? NSNumber)?.uint64Value)
            XCTAssertGreaterThan(next, offset)
            XCTAssertEqual(next - offset, UInt64(bytes.count))
            XCTAssertEqual(result.payload["is_snapshot"] as? Bool, true)
            XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(Data(repeating: 0xff, count: 4096)))
            reconstructed.append(bytes)
            offset = next
            if result.payload["eof"] as? Bool == true { break }
        }
        XCTAssertEqual(reconstructed, Data(repeating: 0xff, count: 4096))
        try Data().write(to: finish)
        let terminal = try await fixture.service.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(terminal.state, .completed)
    }

    func testForcedReaderCloseWithOwnedInheritedWriterCannotReportCompleteOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pipe-baseline-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(jobID: UUID(), projectID: ProjectID(), generation: .initial,
            artifactRoot: artifacts, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
        let ready = project.appendingPathComponent("ready")
        let release = project.appendingPathComponent("release")
        let launcher = try RuntimeLaunchGate.install(serviceRoot: artifacts)
        let script = "printf 'owned-prefix'; printf 'owned-stderr' >&2; printf ready > \"$1\"; i=0; while [ ! -f \"$2\" ]; do i=$((i+1)); [ $i -lt 300 ] || exit 70; /bin/sleep 0.01; done; exit 0"
        let process = try RuntimeActiveProcess(plan: RuntimeProcessPlan(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "owned-inherited-writer", ready.path, release.path],
            workingDirectory: project, environment: ["PATH": "/usr/bin:/bin"], writableRoots: [project]
        ), spool: spool, launcher: launcher)
        defer { process.forceCloseReaders(); spool.discard() }
        var fixtureError: Error?
        do {
            try process.releaseForExecution()
            let started = await Self.waitForFile(ready)
            XCTAssertTrue(started, "The actual owned child must reach its writer-holding barrier")
            process.forceCloseReaders()
            let closedWhileWriterRetained = await process.waitForReaders(maximumMilliseconds: 250)
            XCTAssertTrue(closedWhileWriterRetained, "Force close must stop the reader owner while the child retains its write descriptors")
            try Data().write(to: release)
        } catch {
            fixtureError = error
            process.abortBeforeExecution()
            try? Data().write(to: release)
        }
        let exit = await process.waitForExit(maximumMilliseconds: 4_000)
        XCTAssertEqual(exit?.exitCode, 0, "The bounded actual child must exit zero and be reaped")
        if exit == nil {
            _ = try? await process.terminateAndWait(graceMilliseconds: 100, forcedGraceMilliseconds: 1_000)
        } else {
            try await process.closeDescendants(graceMilliseconds: 100, forcedGraceMilliseconds: 1_000)
        }
        let drained = await process.waitForReaders(maximumMilliseconds: 1_000)
        XCTAssertTrue(drained)
        let outputs = try spool.finalize()
        XCTAssertEqual(outputs.count, 2)
        for output in outputs {
            XCTAssertTrue(output.artifactTruncated, "Forced reader closure cannot certify complete producer output: \(output.stream)")
        }
        if let fixtureError { throw fixtureError }
    }

    func testPipeReaderEOFWaitsForOwnedChildRetainingTheWriter() async throws {
        try await Self.withOwnedPipeWriter { root, spool, reader, release, child, ownedRead in
            reader.start()
            XCTAssertFalse(reader.finished, "The child still owns its pipe writer behind the release barrier")
            try Data().write(to: release)
            let status = try await Self.reapPipeWriter(child)
            XCTAssertEqual(status, 0, "The actual writer must reach a successful native terminal status")
            let closed = await Self.waitForPipeReader(reader)
            XCTAssertTrue(closed)
            reader.close()
            let stdout = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
            XCTAssertEqual(stdout.inlineText, "late-output")
            XCTAssertEqual(stdout.byteCount, 11)
            XCTAssertEqual(stdout.producerEndReason, .eof)
            XCTAssertNil(stdout.producerReadErrno)
            XCTAssertFalse(stdout.artifactTruncated)
        }
    }

    func testForcedPipeCloseStopsItsOwnerBeforeLateChildWriteAndDescriptorReuse() async throws {
        try await Self.withOwnedPipeWriter { root, spool, reader, release, child, ownedRead in
            reader.start()
            reader.close()
            let closed = await Self.waitForPipeReader(reader)
            XCTAssertTrue(closed, "An idle writer cannot retain a forced reader indefinitely")
            let reused = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard reused >= 0 else { throw RuntimeJobError.storageFailure("could not open reuse control") }
            defer { Darwin.close(reused) }
            let exactReuse = reused == ownedRead ? reused : Darwin.fcntl(reused, F_DUPFD_CLOEXEC, ownedRead)
            guard exactReuse >= 0 else { throw RuntimeJobError.storageFailure("could not allocate exact descriptor reuse control") }
            defer { if exactReuse != reused { Darwin.close(exactReuse) } }
            XCTAssertEqual(exactReuse, ownedRead, "This control must actually reuse the released reader descriptor")
            reader.close()
            XCTAssertGreaterThanOrEqual(Darwin.fcntl(exactReuse, F_GETFD), 0,
                "Repeated close cannot close a descriptor allocated after the reader owner finished")
            try Data().write(to: release)
            let status = try await Self.reapPipeWriter(child)
            XCTAssertNotEqual(status, 0, "The late writer must observe the closed actual pipe")
            let stdout = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
            XCTAssertEqual(stdout.byteCount, 0)
            XCTAssertEqual(stdout.producerEndReason, .forcedClose)
            XCTAssertNil(stdout.producerReadErrno)
            XCTAssertTrue(stdout.artifactTruncated)
        }
    }

    func testPipeReaderPersistsActualReadErrorInsteadOfEOF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pipe-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(jobID: UUID(), projectID: ProjectID(), generation: .initial,
            artifactRoot: root, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
        defer { spool.discard() }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw RuntimeJobError.spawnFailed(errno) }
        defer { Darwin.close(descriptors[0]) }
        // Reading the still-open write end produces a real EBADF; no injected reader result.
        let reader = RuntimePipeReader(descriptor: descriptors[1], stream: .stdout, spool: spool)
        reader.start()
        let closed = await Self.waitForPipeReader(reader)
        XCTAssertTrue(closed)
        reader.close()
        let stdout = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
        XCTAssertEqual(stdout.producerEndReason, .readError)
        XCTAssertEqual(stdout.producerReadErrno, EBADF)
        XCTAssertTrue(stdout.artifactTruncated)
        XCTAssertEqual(stdout.byteCount, 0)
    }


    func testPipeCloseBeforeStartCannotBecomeEOFForAnAlreadyClosedWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pipe-close-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(jobID: UUID(), projectID: ProjectID(), generation: .initial,
            artifactRoot: root, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
        defer { spool.discard() }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw RuntimeJobError.spawnFailed(errno) }
        Darwin.close(descriptors[1])
        let reader = RuntimePipeReader(descriptor: descriptors[0], stream: .stdout, spool: spool)
        reader.close()
        reader.start()
        let closed = await Self.waitForPipeReader(reader)
        XCTAssertTrue(closed)
        let stdout = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
        XCTAssertEqual(stdout.producerEndReason, .forcedClose)
        XCTAssertNil(stdout.producerReadErrno)
        XCTAssertTrue(stdout.artifactTruncated)
        XCTAssertEqual(stdout.byteCount, 0)
    }

    func testLegacyOutputDecodesWithoutManufacturingProducerEOF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pipe-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RuntimeOutputSpool(jobID: UUID(), projectID: ProjectID(), generation: .initial,
            artifactRoot: root, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
        defer { spool.discard() }
        spool.append(Data("legacy".utf8), stream: .stdout)
        let stdout = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stdout)) as? [String: Any])
        legacy.removeValue(forKey: "producerEndReason")
        legacy.removeValue(forKey: "producerReadErrno")
        let decoded = try JSONDecoder().decode(RuntimeJobOutputMetadata.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.producerEndReason)
        XCTAssertNil(decoded.producerReadErrno)
        XCTAssertEqual(decoded.inlineText, "legacy")
        XCTAssertEqual(decoded.sha256, stdout.sha256)
        legacy["producerEndReason"] = NSNull(); legacy["producerReadErrno"] = NSNull()
        let explicitNull = try JSONDecoder().decode(RuntimeJobOutputMetadata.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(explicitNull.producerEndReason)
        XCTAssertNil(explicitNull.producerReadErrno)
        legacy["producerEndReason"] = "not_a_producer_end"
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeJobOutputMetadata.self,
            from: JSONSerialization.data(withJSONObject: legacy)))
    }


    func testVersion5OutputRowsMigrateWithoutInventingProducerEOF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-output-v5-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("control.sqlite")
        let control = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        let projectID = ProjectID()
        _ = try await control.registerProjectUnchecked(projectID: projectID, displayName: "Owned V5 Output", canonicalRoot: project)
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "owned-output-v5")
        let scope = ToolAuthorizationScope(canonicalRoots: [project], allowedTools: ["job.read_output"], networkAllowed: false, maximumInlineOutputBytes: 256)
        _ = try await control.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
        let context = try await control.invocationContext(for: owner)
        await control.close()
        let jobID = UUID()
        let artifactRoot = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let spool = try RuntimeOutputSpool(jobID: jobID, projectID: projectID, generation: .initial,
            artifactRoot: artifactRoot, maximumInlineBytes: 8, maximumArtifactBytes: 256)
        defer { spool.discard() }
        spool.append(Data("legacy stdout bytes\n".utf8), stream: .stdout)
        let originals = try spool.finalize()
        let database = try Self.openSQLiteFixture(at: databaseURL)
        do {
            // Verbatim inspected v5 runtime schema; the co-resident control plane
            // already owns execution_jobs, so add its v5 process-identity columns.
            let schema = """
            CREATE TABLE IF NOT EXISTS runtime_job_schema_version (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                version INTEGER NOT NULL CHECK(version>=1),
                applied_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS execution_jobs (
                job_id TEXT PRIMARY KEY,
                run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
                project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
                project_generation INTEGER NOT NULL CHECK(project_generation>=1),
                runtime_kind TEXT NOT NULL CHECK(runtime_kind IN ('process','shell','bash','python','powershell')),
                execution_profile TEXT NOT NULL CHECK(execution_profile IN (
                    'direct_process','zsh_no_profile','bash_no_profile','legacy_bash_login',
                    'python_isolated','powershell_no_profile')),
                replay_class TEXT NOT NULL CHECK(replay_class IN ('read_only','idempotent','reconciled','non_replayable')),
                idempotency_key TEXT,
                state TEXT NOT NULL CHECK(state IN (
                    'queued','running','cancelling','completed','failed','timed_out','cancelled','quarantined_stale')),
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
                process_start_seconds INTEGER CHECK(process_start_seconds>0),
                process_start_microseconds INTEGER CHECK(
                    process_start_microseconds>=0 AND process_start_microseconds<1000000
                ),
                created_at TEXT NOT NULL,
                started_at TEXT,
                completed_at TEXT,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_jobs_project_state
                ON execution_jobs(project_id,project_generation,state);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_project_idempotency
                ON execution_jobs(project_id,project_generation,idempotency_key)
                WHERE idempotency_key IS NOT NULL;

            CREATE TABLE IF NOT EXISTS runtime_job_details (
                job_id TEXT PRIMARY KEY REFERENCES execution_jobs(job_id) ON DELETE CASCADE,
                request_artifact_relative_path TEXT,
                error_code TEXT,
                error_summary TEXT,
                termination_phase TEXT NOT NULL DEFAULT 'idle' CHECK(termination_phase IN (
                    'idle','term_pending','term_sent','kill_pending','kill_sent','confirmed','unconfirmed'
                )),
                termination_probe_deadline TEXT,
                termination_error_summary TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS runtime_job_output_streams (
                job_id TEXT NOT NULL REFERENCES execution_jobs(job_id) ON DELETE CASCADE,
                stream TEXT NOT NULL CHECK(stream IN ('stdout','stderr')),
                inline_text TEXT NOT NULL,
                artifact_relative_path TEXT,
                artifact_device_identifier INTEGER CHECK(artifact_device_identifier>=0),
                artifact_file_identifier INTEGER CHECK(artifact_file_identifier>=0),
                byte_count INTEGER NOT NULL CHECK(byte_count>=0),
                retained_byte_count INTEGER NOT NULL CHECK(retained_byte_count>=0),
                sha256 TEXT NOT NULL,
                inline_truncated INTEGER NOT NULL CHECK(inline_truncated IN (0,1)),
                artifact_truncated INTEGER NOT NULL CHECK(artifact_truncated IN (0,1)),
                artifact_evicted_at TEXT,
                PRIMARY KEY(job_id,stream)
            );
            CREATE TABLE IF NOT EXISTS runtime_job_idempotency_receipts (
                job_id TEXT PRIMARY KEY,
                run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
                project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
                project_generation INTEGER NOT NULL CHECK(project_generation>=1),
                runtime_kind TEXT NOT NULL CHECK(runtime_kind IN ('process','shell','bash','python','powershell')),
                execution_profile TEXT NOT NULL CHECK(execution_profile IN (
                    'direct_process','zsh_no_profile','bash_no_profile','legacy_bash_login',
                    'python_isolated','powershell_no_profile')),
                replay_class TEXT NOT NULL CHECK(replay_class IN (
                    'read_only','idempotent','reconciled','non_replayable')),
                idempotency_key TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN (
                    'completed','failed','timed_out','cancelled','quarantined_stale')),
                canonical_cwd TEXT NOT NULL,
                command_summary TEXT NOT NULL,
                timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds>0),
                exit_code INTEGER,
                output_bytes INTEGER NOT NULL CHECK(output_bytes>=0),
                error_code TEXT,
                error_summary TEXT,
                created_at TEXT NOT NULL,
                started_at TEXT,
                completed_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                compacted_at TEXT NOT NULL,
                UNIQUE(project_id,project_generation,idempotency_key)
            );
            CREATE INDEX IF NOT EXISTS idx_runtime_job_receipts_project_completed
                ON runtime_job_idempotency_receipts(project_id,project_generation,completed_at DESC);
            """
            try Self.executeSQLiteFixture(schema, database: database)
            try Self.executeSQLiteFixture("""
                ALTER TABLE execution_jobs ADD COLUMN process_start_seconds INTEGER CHECK(process_start_seconds>0);
                ALTER TABLE execution_jobs ADD COLUMN process_start_microseconds INTEGER CHECK(process_start_microseconds>=0 AND process_start_microseconds<1000000);
                INSERT INTO runtime_job_schema_version(singleton,version,applied_at) VALUES(1,5,'2026-10-06T00:00:00Z');
                """, database: database)
            func text(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
            func optionalText(_ value: String?) -> String { value.map(text) ?? "NULL" }
            func optionalInteger(_ value: UInt64?) -> String { value.map(String.init) ?? "NULL" }
            let job = jobID.uuidString.lowercased()
            try Self.executeSQLiteFixture("""
                INSERT INTO execution_jobs(job_id,project_id,project_generation,runtime_kind,execution_profile,replay_class,state,canonical_cwd,command_summary,timeout_seconds,exit_code,output_bytes,created_at,completed_at,updated_at)
                VALUES('\(job)','\(projectID.description)',1,'process','direct_process','read_only','completed',\(text(project.path)),'owned pre-v6 output fixture',5,0,20,'2026-10-06T00:00:00Z','2026-10-06T00:00:01Z','2026-10-06T00:00:01Z');
                """, database: database)
            for output in originals {
                try Self.executeSQLiteFixture("""
                    INSERT INTO runtime_job_output_streams(job_id,stream,inline_text,artifact_relative_path,artifact_device_identifier,artifact_file_identifier,byte_count,retained_byte_count,sha256,inline_truncated,artifact_truncated)
                    VALUES('\(job)',\(text(output.stream.rawValue)),\(text(output.inlineText)),\(optionalText(output.artifactRelativePath)),\(optionalInteger(output.artifactDeviceIdentifier)),\(optionalInteger(output.artifactFileIdentifier)),\(output.byteCount),\(output.retainedByteCount),\(text(output.sha256)),\(output.inlineTruncated ? 1 : 0),\(output.artifactTruncated ? 1 : 0));
                    """, database: database)
            }
        } catch { sqlite3_close(database); throw error }
        sqlite3_close(database)
        XCTAssertEqual(try Self.sqliteCount(databaseURL: databaseURL,
            sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"), 5)
        XCTAssertEqual(try Self.sqliteCount(databaseURL: databaseURL,
            sql: "SELECT COUNT(*) FROM runtime_job_output_streams"), 2)
        let repository = try RuntimeJobRepository(databaseURL: databaseURL)
        for original in originals {
            let output = try await repository.output(jobID: jobID, stream: original.stream, context: context)
            XCTAssertEqual(output, original, "Migration must preserve bytes, hash, artifact identity, and unknown producer end")
            XCTAssertNil(output.producerEndReason)
            XCTAssertNil(output.producerReadErrno)
        }
        let record = try await repository.job(jobID, context: context)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await repository.close()
        let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)))
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.sourceVersion, 5)
        XCTAssertEqual(manifest.targetVersion, 6)
        let backup = root.appendingPathComponent("control.pre-migration-v5.sqlite3")
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertEqual(manifest.backupSHA256, JSONSupport.sha256Hex(backupBytes))
        XCTAssertEqual(try Self.sqliteCount(databaseURL: backup,
            sql: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"), 5)
        let reopened = try RuntimeJobRepository(databaseURL: databaseURL)
        for original in originals {
            let output = try await reopened.output(jobID: jobID, stream: original.stream, context: context)
            XCTAssertEqual(output, original)
        }
        await reopened.close()
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes, "Reopen cannot create a replacement migration backup")
        XCTAssertEqual(try Self.sqliteCount(databaseURL: databaseURL,
            sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id='\(manifest.migrationID)'"), 1)
    }


    func testProducerLossAndErrnoCannotBypassDurableOutputValidation() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let invalid: [(RuntimeOutputProducerEndReason?, Int32?, Bool)] = [
                (.readError, EBADF, false), (.forcedClose, nil, false),
                (.readError, nil, true), (.eof, EBADF, false),
                (.forcedClose, EBADF, true), (nil, EBADF, false),
            ]
            for (reason, readErrno, truncated) in invalid {
                let jobID = UUID()
                _ = try await fixture.runtimeRepository.createJob(jobID: jobID,
                    request: fixture.request(kind: .bash, profile: .bashNoProfile, script: "exit 0", timeout: 5),
                    commandSummary: "owned unlaunched producer validation", timeoutSeconds: 5, requestArtifactRelativePath: nil)
                let artifactRoot = fixture.root.appendingPathComponent("validation-artifacts")
                try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
                let spool = try RuntimeOutputSpool(jobID: jobID, projectID: fixture.context.projectID, generation: .initial,
                    artifactRoot: artifactRoot, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
                spool.append(Data("owned".utf8), stream: .stdout)
                let original = try XCTUnwrap(try spool.finalize().first { $0.stream == .stdout })
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
                object["producerEndReason"] = reason?.rawValue as Any? ?? NSNull()
                object["producerReadErrno"] = readErrno as Any? ?? NSNull()
                object["artifactTruncated"] = truncated
                let rejected = try JSONDecoder().decode(RuntimeJobOutputMetadata.self,
                    from: JSONSerialization.data(withJSONObject: object))
                do {
                    _ = try await fixture.runtimeRepository.complete(jobID: jobID, terminalState: .failed,
                        exitCode: 1, outputs: [rejected], artifactID: nil, expectedContext: fixture.context)
                    XCTFail("Invalid producer metadata reached durable output: \(reason?.rawValue ?? "unknown")")
                } catch let error as RuntimeJobError {
                    XCTAssertEqual(error.code, "invalid_request")
                }
                let queued = try await fixture.runtimeRepository.job(jobID, context: fixture.context)
                XCTAssertEqual(queued.state, .queued, "The failed write must roll its job transition back")
                _ = try await fixture.runtimeRepository.complete(jobID: jobID, terminalState: .failed,
                    exitCode: 1, outputs: [original], artifactID: nil, expectedContext: fixture.context)
                let databaseURL = await fixture.runtimeRepository.databaseURL
                let database = try Self.openSQLiteFixture(at: databaseURL)
                do {
                    let value = reason.map { "'" + $0.rawValue + "'" } ?? "NULL"
                    let number = readErrno.map(String.init) ?? "NULL"
                    try Self.executeSQLiteFixture("UPDATE runtime_job_output_streams SET producer_end_reason=\(value),producer_read_errno=\(number),artifact_truncated=\(truncated ? 1 : 0) WHERE job_id='\(jobID.uuidString.lowercased())' AND stream='stdout'", database: database)
                    XCTAssertEqual(sqlite3_changes(database), 1)
                } catch { sqlite3_close(database); throw error }
                sqlite3_close(database)
                do {
                    _ = try await fixture.runtimeRepository.output(jobID: jobID, stream: .stdout, context: fixture.context)
                    XCTFail("Invalid durable producer metadata was decoded")
                } catch let error as RuntimeJobError { XCTAssertEqual(error.code, "runtime_storage_failure") }
                spool.discard()
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    private static func waitForPipeReader(_ reader: RuntimePipeReader) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !reader.finished && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reader.finished
    }

    private static func reapPipeWriter(_ child: Int32) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            var status: Int32 = 0
            let result = Darwin.waitpid(child, &status, WNOHANG)
            if result == child { return status }
            if result < 0, errno != EINTR { throw RuntimeJobError.storageFailure("owned pipe writer could not be reaped") }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuntimeJobError.storageFailure("owned pipe writer exceeded its bounded deadline")
    }

    private static func withOwnedPipeWriter(
        body: (URL, RuntimeOutputSpool, RuntimePipeReader, URL, Int32, Int32) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pipe-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactRoot = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let spool = try RuntimeOutputSpool(jobID: UUID(), projectID: ProjectID(), generation: .initial,
            artifactRoot: artifactRoot, maximumInlineBytes: 256, maximumArtifactBytes: 1_024)
        defer { spool.discard() }
        let release = root.appendingPathComponent("release")
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw RuntimeJobError.spawnFailed(errno) }
        let ownedRead = Darwin.fcntl(descriptors[0], F_DUPFD_CLOEXEC, 128)
        guard ownedRead >= 0 else {
            descriptors.forEach { Darwin.close($0) }
            throw RuntimeJobError.storageFailure("could not allocate owned reader descriptor")
        }
        Darwin.close(descriptors[0]); descriptors[0] = ownedRead
        var transferredRead = false
        defer {
            if !transferredRead { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw RuntimeJobError.storageFailure("pipe writer actions failed") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw RuntimeJobError.storageFailure("pipe writer attributes failed") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw RuntimeJobError.storageFailure("pipe writer descriptor isolation failed")
        }
        guard posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 else {
            throw RuntimeJobError.storageFailure("pipe writer file actions failed")
        }
        let script = "i=0; while [ ! -f \"$1\" ]; do i=$((i+1)); [ $i -lt 200 ] || exit 70; /bin/sleep 0.01; done; printf late-output"
        var arguments = ["/bin/sh", "-c", script, "owned-pipe-writer", release.path].map { strdup($0) } + [nil]
        var environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for pointer in arguments { free(pointer) }
            for pointer in environment { free(pointer) }
        }
        var child: Int32 = 0
        let spawned = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard spawned == 0 else { throw RuntimeJobError.spawnFailed(spawned) }
        Darwin.close(descriptors[1]); descriptors[1] = -1
        let reader = RuntimePipeReader(descriptor: descriptors[0], stream: .stdout, spool: spool)
        transferredRead = true
        do { try await body(root, spool, reader, release, child, ownedRead) }
        catch {
            reader.close()
            var pendingStatus: Int32 = 0
            if Darwin.waitpid(child, &pendingStatus, WNOHANG) == 0 {
                _ = Darwin.kill(child, SIGKILL)
                _ = try? await reapPipeWriter(child)
            }
            _ = await waitForPipeReader(reader)
            throw error
        }
        reader.close()
        _ = await waitForPipeReader(reader)
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
        XCTAssertEqual(stdout.producerEndReason, .eof)
        XCTAssertEqual(stderr.producerEndReason, .eof)
        XCTAssertNil(stdout.producerReadErrno)
        XCTAssertNil(stderr.producerReadErrno)
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

    func testStoredContextCancellationTargetsExactlyOneQueuedOrActiveJob() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "while :; do sleep 1; done",
                timeout: 30
            )
        )
        let second = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "while :; do sleep 1; done",
                timeout: 30
            )
        )
        let queued = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "while :; do sleep 1; done",
                timeout: 30
            )
        )
        let firstRunning = await fixture.waitForState(first, expected: .running)
        let secondRunning = await fixture.waitForState(second, expected: .running)
        let thirdQueued = await fixture.waitForState(queued, expected: .queued)
        XCTAssertTrue(firstRunning)
        XCTAssertTrue(secondRunning)
        XCTAssertTrue(thirdQueued)

        let queuedReceipt = try await fixture.service.cancelStoredJob(jobID: queued)
        XCTAssertEqual(queuedReceipt.jobID, queued)
        XCTAssertEqual(queuedReceipt.state, .cancelled)
        let firstBeforeActiveCancellation = try await fixture.service.status(
            jobID: first,
            context: fixture.context
        )
        let secondBeforeActiveCancellation = try await fixture.service.status(
            jobID: second,
            context: fixture.context
        )
        XCTAssertEqual(firstBeforeActiveCancellation.state, .running)
        XCTAssertEqual(secondBeforeActiveCancellation.state, .running)

        let storedContext = try await fixture.controlRepository.invocationContext(
            for: ProjectBindingOwner(
                kind: .runtimeJob,
                id: first.uuidString.lowercased()
            )
        )
        XCTAssertEqual(storedContext.runtimeJobID, first)
        XCTAssertEqual(storedContext.projectID, fixture.projectID)
        XCTAssertEqual(storedContext.authorizationScope, fixture.context.authorizationScope)

        let receipt = try await fixture.service.cancelStoredJob(jobID: first)
        XCTAssertEqual(receipt.jobID, first)
        XCTAssertTrue(receipt.state == .cancelling || receipt.state == .cancelled)
        let firstCancelled = await fixture.waitForState(first, expected: .cancelled)
        XCTAssertTrue(firstCancelled)
        let secondStatus = try await fixture.service.status(
            jobID: second,
            context: fixture.context
        )
        XCTAssertEqual(secondStatus.state, .running)

        try await fixture.service.cancel(jobID: second, context: fixture.context)
        let secondCancelled = await fixture.waitForState(second, expected: .cancelled)
        XCTAssertTrue(secondCancelled)
        await fixture.close()
    }

    func testOperatorCancellationStatePolicyAllowsOnlyQueuedAndRunningJobs() {
        XCTAssertEqual(
            Set(RuntimeJobState.allCases.filter(\.isOperatorCancellable)),
            Set([.queued, .running])
        )
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
        let observer = BeforeTerminationDescendantWitness()
        let fixture = try await Fixture.make(
            limits: limits,
            recoveredProcessController: observer
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let pidFile = fixture.projectRoot.appendingPathComponent("fork-tree.pids")
            await observer.setPIDFile(pidFile)
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
            let state = await observer.captured()
            XCTAssertNil(state.failure)
            XCTAssertEqual(state.delegatedTermination, .signaled)
            let capture = try XCTUnwrap(state.capture)
            let observedPIDs = Set(capture.children.map(\.processIdentifier))
            XCTAssertGreaterThan(observedPIDs.count, limits.maximumDescendantProcessesPerJob)
            let pids = try String(contentsOf: pidFile, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
            for pid in pids {
                let descendantGone = await Self.waitUntilProcessIsGone(pid)
                XCTAssertTrue(descendantGone, "descendant \(pid) survived")
            }
            for identity in capture.children {
                let exactIdentityGone = await Self.waitUntil {
                    if let current = RuntimeProcessIdentityReader.observedIdentity(
                        processIdentifier: identity.processIdentifier
                    ) {
                        return current.startIdentity != identity.startIdentity
                    }
                    return Darwin.kill(identity.processIdentifier, 0) != 0 && errno == ESRCH
                }
                XCTAssertTrue(
                    exactIdentityGone,
                    "captured exact descendant \(identity.processIdentifier) survived"
                )
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testDescendantBudgetTerminationCanPrecedeShellPIDRecording() async throws {
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
        let observer = BeforeTerminationDescendantWitness()
        let fixture = try await Fixture.make(
            limits: limits,
            recoveredProcessController: observer
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let pidFile = fixture.projectRoot.appendingPathComponent("fork-tree.pids")
            await observer.setPIDFile(pidFile)
            let script = """
            : > fork-tree.pids
            i=0
            while [ "$i" -lt 2 ]; do
              sleep 30 &
              echo $! >> fork-tree.pids
              i=$((i + 1))
            done
            sleep 30 &
            unrecorded_pid=$!
            SECONDS=0
            while [ "$SECONDS" -lt 2 ]; do :; done
            echo "$unrecorded_pid" >> fork-tree.pids
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
            let state = await observer.captured()
            XCTAssertNil(state.failure)
            XCTAssertEqual(state.delegatedTermination, .signaled)
            let capture = try XCTUnwrap(state.capture)
            // Shell PID recording can lag the owned kernel child count.
            XCTAssertEqual(Set(capture.shellPIDs).count, 2)
            let observedPIDs = Set(capture.children.map(\.processIdentifier))
            XCTAssertEqual(observedPIDs.count, 3)
            XCTAssertGreaterThan(observedPIDs.count, limits.maximumDescendantProcessesPerJob)
            XCTAssertTrue(Set(capture.shellPIDs).isSubset(of: observedPIDs))

            // Retain the original shell-PID cleanup contract.
            let originalPIDs = try String(contentsOf: pidFile, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
            for pid in originalPIDs {
                let gone = await Self.waitUntilProcessIsGone(pid)
                XCTAssertTrue(gone, "shell-listed descendant \(pid) survived")
            }
            // Also cover the child that had not been written to the shell file.
            for identity in capture.children {
                let exactIdentityGone = await Self.waitUntil {
                    if let current = RuntimeProcessIdentityReader.observedIdentity(
                        processIdentifier: identity.processIdentifier
                    ) {
                        return current.startIdentity != identity.startIdentity
                    }
                    return Darwin.kill(identity.processIdentifier, 0) != 0 && errno == ESRCH
                }
                XCTAssertTrue(
                    exactIdentityGone,
                    "captured exact descendant \(identity.processIdentifier) survived"
                )
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private actor BeforeTerminationDescendantWitness: RuntimeRecoveredProcessControlling {
        struct Capture: Sendable {
            let root: RuntimeObservedProcessIdentity
            let children: [RuntimeObservedProcessIdentity]
            let shellPIDs: [Int32]
        }

        struct State: Sendable {
            let capture: Capture?
            let failure: String?
            let delegatedTermination: RuntimeRecoveredProcessSignalResult?
        }

        private let delegate = DarwinRuntimeRecoveredProcessController()
        private let reader = DarwinRuntimeProcessTreeReader()
        private var pidFile: URL?
        private var attemptedFirstTermination = false
        private var capture: Capture?
        private var failure: String?
        private var delegatedTermination: RuntimeRecoveredProcessSignalResult?

        func setPIDFile(_ url: URL) { pidFile = url }

        func captured() -> State {
            State(
                capture: capture,
                failure: failure,
                delegatedTermination: delegatedTermination
            )
        }

        func signalProcessGroup(
            _ signal: Int32,
            expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            let capturesThisCall = signal == SIGTERM && !attemptedFirstTermination
            if capturesThisCall {
                attemptedFirstTermination = true
                do {
                    capture = try captureBeforeSignal(expectedIdentity)
                } catch {
                    failure = String(decoding: Array(error.localizedDescription.utf8.prefix(1_024)), as: UTF8.self)
                }
            }
            // Capture failures must never prevent real cleanup or alter signaling.
            let result = await delegate.signalProcessGroup(signal, expectedIdentity: expectedIdentity)
            if capturesThisCall { delegatedTermination = result }
            return result
        }

        private func captureBeforeSignal(
            _ expected: RuntimePersistedProcessIdentity
        ) throws -> Capture {
            guard let pidFile,
                  let before = reader.identity(processIdentifier: expected.processIdentifier),
                  before.processIdentifier == expected.processIdentifier,
                  before.processGroupIdentifier == expected.processGroupIdentifier,
                  before.startIdentity == expected.startIdentity else {
                throw RuntimeJobError.invalidRequest("owned root identity unavailable before signal")
            }
            let listed = reader.children(of: before.processIdentifier, maximumCount: 16)
            guard listed.complete,
                  Set(listed.processIdentifiers).count == listed.processIdentifiers.count else {
                throw RuntimeJobError.invalidRequest("bounded direct-child snapshot incomplete")
            }
            var children: [RuntimeObservedProcessIdentity] = []
            for pid in listed.processIdentifiers {
                guard let child = reader.identity(processIdentifier: pid),
                      child.parentProcessIdentifier == before.processIdentifier,
                      child.processGroupIdentifier == before.processGroupIdentifier else {
                    throw RuntimeJobError.invalidRequest("direct child identity unavailable before signal")
                }
                children.append(child)
            }
            let file = try FileHandle(forReadingFrom: pidFile)
            defer { try? file.close() }
            let data = try file.read(upToCount: 8_193) ?? Data()
            guard data.count <= 8_192,
                  let text = String(data: data, encoding: .utf8) else {
                throw RuntimeJobError.invalidRequest("bounded shell PID file unavailable")
            }
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count <= 16 else {
                throw RuntimeJobError.invalidRequest("bounded shell PID entry count exceeded")
            }
            let shellPIDs = try lines.map { line -> Int32 in
                guard let pid = Int32(line), pid > 1 else {
                    throw RuntimeJobError.invalidRequest("invalid owned shell PID entry")
                }
                return pid
            }
            guard reader.identity(processIdentifier: before.processIdentifier) == before else {
                throw RuntimeJobError.invalidRequest("owned root changed during bounded snapshot")
            }
            return Capture(root: before, children: children, shellPIDs: shellPIDs)
        }
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

    func testPersistentTerminationFailureBecomesBoundedCleanupDebtAndReleasesOwnership() async throws {
        let controller = SwitchableRecoveredProcessController(failing: true)
        let policy = ExecutionJobService.RuntimeTerminationRecoveryPolicy(
            maximumAttempts: 2,
            maximumDurationMilliseconds: 500,
            initialDelayMilliseconds: 1,
            maximumDelayMilliseconds: 2
        )
        let fixture = try await Fixture.make(
            recoveredProcessController: controller,
            terminationRecoveryPolicy: policy
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
        let persistedIdentity = try await fixture.runtimeRepository.recoveryProcessIdentity(
            jobID: jobID
        )
        let identity = try XCTUnwrap(persistedIdentity)
        defer {
            if RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: identity.processIdentifier
            )?.startIdentity == identity.startIdentity {
                _ = Darwin.kill(-identity.processGroupIdentifier, SIGKILL)
                _ = Darwin.kill(identity.processIdentifier, SIGKILL)
            }
        }

        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let terminal = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(5)
        )
        XCTAssertEqual(terminal.state, .failed)
        XCTAssertEqual(terminal.errorCode, "runtime_termination_unconfirmed")
        XCTAssertTrue(terminal.errorSummary?.contains("cleanup_debt=true") == true)
        XCTAssertTrue(terminal.errorSummary?.contains("attempts=2") == true)
        XCTAssertTrue(terminal.errorSummary?.contains("maximum_attempts=2") == true)
        XCTAssertTrue(terminal.errorSummary?.contains("recovery_window_ms=500") == true)
        XCTAssertLessThanOrEqual(terminal.errorSummary?.utf8.count ?? .max, 2_048)
        let recoveryPending = await fixture.service.recoveryPendingJobIDs()
        XCTAssertFalse(recoveryPending.contains(jobID))

        let artifactDirectory = fixture.root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(fixture.projectID.description, isDirectory: true)
            .appendingPathComponent(String(fixture.context.projectGeneration.rawValue), isDirectory: true)
            .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
        let report = await fixture.service.shutdown()
        XCTAssertTrue(report.completed)
        XCTAssertTrue(report.unresolvedJobIDs.isEmpty)
        await fixture.runtimeRepository.close()
        await fixture.controlRepository.close()
    }

    func testTerminalCleanupDebtReceivesOnlyOneBoundedStartupRetry() async throws {
        let liveController = SwitchableRecoveredProcessController(failing: true)
        let policy = ExecutionJobService.RuntimeTerminationRecoveryPolicy(
            maximumAttempts: 1,
            maximumDurationMilliseconds: 500,
            initialDelayMilliseconds: 1,
            maximumDelayMilliseconds: 1
        )
        let fixture = try await Fixture.make(
            recoveredProcessController: liveController,
            terminationRecoveryPolicy: policy
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
        let storedIdentity = try await fixture.runtimeRepository.recoveryProcessIdentity(
            jobID: jobID
        )
        let identity = try XCTUnwrap(storedIdentity)
        defer {
            if RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: identity.processIdentifier
            )?.startIdentity == identity.startIdentity {
                _ = Darwin.kill(-identity.processGroupIdentifier, SIGKILL)
                _ = Darwin.kill(identity.processIdentifier, SIGKILL)
            }
        }

        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let debt = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(5)
        )
        XCTAssertEqual(debt.errorCode, "runtime_termination_unconfirmed")
        XCTAssertTrue(debt.errorSummary?.contains("restart_attempts=0") == true)
        _ = await fixture.service.shutdown()
        await fixture.runtimeRepository.close()

        let databaseURL = fixture.root.appendingPathComponent("control-plane.sqlite")
        let retryRepository = try RuntimeJobRepository(databaseURL: databaseURL)
        let retryProbe = RecoveredSignalProbe(result: .signalFailed(EPERM))
        let retryService = try ExecutionJobService(
            repository: retryRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await retryService.setRecoveredProcessController(retryProbe)
        try await retryService.start()
        let retrySignals = await retryProbe.signals()
        XCTAssertEqual(retrySignals, [SIGKILL])
        let attempted = try await retryRepository.job(jobID)
        XCTAssertEqual(attempted?.errorCode, "runtime_termination_unconfirmed")
        XCTAssertTrue(attempted?.errorSummary?.contains("restart_attempts=1") == true)
        XCTAssertTrue(attempted?.errorSummary?.contains("cleanup_debt_resolved=false") == true)
        _ = await retryService.shutdown()
        await retryRepository.close()

        let finalRepository = try RuntimeJobRepository(databaseURL: databaseURL)
        let finalProbe = RecoveredSignalProbe(result: .processMissing)
        let finalService = try ExecutionJobService(
            repository: finalRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(
                repository: fixture.controlRepository
            ),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await finalService.setRecoveredProcessController(finalProbe)
        try await finalService.start()
        let finalSignals = await finalProbe.signals()
        XCTAssertTrue(finalSignals.isEmpty)
        _ = await finalService.shutdown()
        await finalRepository.close()
        await fixture.controlRepository.close()
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

    func testWritableRootMetadataDoesNotRestrictNativeRuntimeWrites() async throws {
        let fixture = try await Fixture.make(readOnlyProject: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let input = fixture.projectRoot.appendingPathComponent("read-only-input")
        let nativeOutput = fixture.projectRoot.appendingPathComponent("native-write")
        try Data("read-visible".utf8).write(to: input, options: .atomic)

        let jobID = try await fixture.service.submit(
            fixture.request(
                kind: .bash,
                profile: .bashNoProfile,
                script: "cat read-only-input; printf native > native-write",
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
        XCTAssertEqual(try String(contentsOf: nativeOutput, encoding: .utf8), "native")
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

    func testStagedScriptDoesNotRevealManagerOutputDirectory() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = """
        output_directory=${0%/*}
        if [ -e "$output_directory/stdout.log" ]; then exit 91; fi
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
        let outputColumns = try Self.sqliteColumnNames(databaseURL: databaseURL, table: "runtime_job_output_streams")
        XCTAssertTrue(outputColumns.contains("producer_end_reason"))
        XCTAssertTrue(outputColumns.contains("producer_read_errno"))

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

    func testRuntimeLaunchGateApprovesOnlyProductSigningTeams() {
        XCTAssertEqual(RuntimeLaunchGate.developmentTeamIdentifier, "9AQ2C2838M")
        XCTAssertEqual(RuntimeLaunchGate.distributionTeamIdentifier, "2Y25RTLZET")
        XCTAssertEqual(
            RuntimeLaunchGate.approvedProductTeamIdentifiers,
            ["9AQ2C2838M", "2Y25RTLZET"]
        )
    }

    func testRuntimeLaunchGateRecognizesCurrentAndLegacySwiftPackageTestIdentities() {
        XCTAssertTrue(RuntimeLaunchGate.isSwiftPackageTestIdentity("ForgeConductorPackageTests"))
        XCTAssertTrue(RuntimeLaunchGate.isSwiftPackageTestIdentity(
            "forge-conductor.ForgeConductorTests"
        ))
        XCTAssertFalse(RuntimeLaunchGate.isSwiftPackageTestIdentity(
            "OtherPackage.ForgeConductorTests"
        ))
        XCTAssertFalse(RuntimeLaunchGate.isSwiftPackageTestIdentity("forge-conductor.OtherTests"))
    }

    func testRuntimeLaunchGateMapsActiveAndEarlierTeamsToTheBuildCertificateClass() throws {
        let development = try XCTUnwrap(
            RuntimeLaunchGate.requiredProductCodeSigningRequirement(
                identifier: RuntimeLaunchGate.productIdentifier,
                teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier
            )
        )
        XCTAssertTrue(development.contains("anchor apple generic"))
        XCTAssertTrue(development.contains("9AQ2C2838M"))
        #if DEBUG || FORGE_DEVELOPMENT_SIGNING
        XCTAssertTrue(development.contains("1.2.840.113635.100.6.1.12"))
        XCTAssertFalse(development.contains("1.2.840.113635.100.6.1.13"))
        #else
        XCTAssertTrue(development.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertFalse(development.contains("1.2.840.113635.100.6.1.12"))
        #endif

        let distribution = try XCTUnwrap(
            RuntimeLaunchGate.requiredProductCodeSigningRequirement(
                identifier: RuntimeLaunchGate.productIdentifier,
                teamIdentifier: RuntimeLaunchGate.distributionTeamIdentifier
            )
        )
        XCTAssertTrue(distribution.contains("anchor apple generic"))
        XCTAssertTrue(distribution.contains("2Y25RTLZET"))
        XCTAssertTrue(distribution.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertFalse(distribution.contains("1.2.840.113635.100.6.1.12"))
        XCTAssertNil(
            RuntimeLaunchGate.requiredProductCodeSigningRequirement(
                identifier: RuntimeLaunchGate.productIdentifier,
                teamIdentifier: "UNAPPROVED1"
            )
        )
    }

    func testRuntimeLaunchGateDevelopmentTestRequirementIsNarrowAndCompiles() throws {
        XCTAssertNil(
            RuntimeLaunchGate.requiredProductCodeSigningRequirement(
                identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier
            ),
            "the test bundle must not become a production product role"
        )
        XCTAssertNil(
            RuntimeLaunchGate.requiredProductCodeSigningRequirement(
                identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                teamIdentifier: RuntimeLaunchGate.distributionTeamIdentifier
            ),
            "the test bundle must not become a distribution product role"
        )

        let requirement = try XCTUnwrap(
            RuntimeLaunchGate.requiredDevelopmentTestCodeSigningRequirement(
                identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier
            )
        )
        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.forge-conductor.tests\" "
                + "and certificate leaf[subject.OU] = \"9AQ2C2838M\" "
                + "and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        )
        XCTAssertFalse(requirement.contains("1.2.840.113635.100.6.1.13"))

        var compiledRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                requirement as CFString,
                SecCSFlags(rawValue: 0),
                &compiledRequirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(compiledRequirement)
        XCTAssertNil(
            RuntimeLaunchGate.requiredDevelopmentTestCodeSigningRequirement(
                identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                teamIdentifier: RuntimeLaunchGate.distributionTeamIdentifier
            )
        )
        XCTAssertNil(
            RuntimeLaunchGate.requiredDevelopmentTestCodeSigningRequirement(
                identifier: "com.forge-conductor.uitests",
                teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier
            )
        )
    }

    func testRuntimeLaunchGateAcceptsDevelopmentAndDistributionSignedCLIProducts() throws {
        let executableDirectory = URL(
            fileURLWithPath: "/tmp/forge-runtime-signed-cli",
            isDirectory: true
        )
        let executable = executableDirectory.appendingPathComponent("forge-conductor")
        let helper = executableDirectory.appendingPathComponent("forge-runtime-launcher")

        for team in RuntimeLaunchGate.approvedProductTeamIdentifiers {
            XCTAssertNoThrow(
                try RuntimeLaunchGate.validateCommandLineProductIdentity(
                    source: helper,
                    sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                        identifier: RuntimeLaunchGate.productIdentifier,
                        teamIdentifier: team,
                        flags: [],
                        uniqueHash: Data(repeating: 0x31, count: 20)
                    ),
                    currentExecutable: executable,
                    currentIdentity: RuntimeLaunchGate.CodeIdentity(
                        identifier: "com.forge-conductor.cli",
                        teamIdentifier: team,
                        flags: [],
                        uniqueHash: Data(repeating: 0x32, count: 20)
                    )
                )
            )
        }
    }

    func testRuntimeLaunchGateAcceptsOnlyDevelopmentSignedXcodeTestParent() throws {
        let executableDirectory = URL(
            fileURLWithPath: "/tmp/forge-runtime-signed-xcode-test",
            isDirectory: true
        )
        let executable = executableDirectory.appendingPathComponent("ForgeConductorTests")
        let helper = executableDirectory.appendingPathComponent("forge-runtime-launcher")

        XCTAssertNoThrow(
            try RuntimeLaunchGate.validateCommandLineProductIdentity(
                source: helper,
                sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.productIdentifier,
                    teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier,
                    flags: [],
                    uniqueHash: Data(repeating: 0x36, count: 20)
                ),
                currentExecutable: executable,
                currentIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                    teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier,
                    flags: [],
                    uniqueHash: Data(repeating: 0x37, count: 20)
                )
            )
        )

        for rejectedTeam in [RuntimeLaunchGate.distributionTeamIdentifier, nil] {
            XCTAssertThrowsError(
                try RuntimeLaunchGate.validateCommandLineProductIdentity(
                    source: helper,
                    sourceIdentity: RuntimeLaunchGate.CodeIdentity(
                        identifier: RuntimeLaunchGate.productIdentifier,
                        teamIdentifier: rejectedTeam,
                        flags: rejectedTeam == nil ? .adhoc : [],
                        uniqueHash: Data(repeating: 0x38, count: 20)
                    ),
                    currentExecutable: executable,
                    currentIdentity: RuntimeLaunchGate.CodeIdentity(
                        identifier: RuntimeLaunchGate.developmentTestBundleIdentifier,
                        teamIdentifier: rejectedTeam,
                        flags: rejectedTeam == nil ? .adhoc : [],
                        uniqueHash: Data(repeating: 0x39, count: 20)
                    )
                )
            )
        }
    }

    func testRuntimeLaunchGateInstallsProductLauncherFromTestHost() throws {
        let serviceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-runtime-signed-test-install-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: serviceRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: serviceRoot) }

        let installed = try RuntimeLaunchGate.install(serviceRoot: serviceRoot)
        XCTAssertTrue(installed.lastPathComponent.hasPrefix(
            RuntimeLaunchGate.executableName + "-"
        ))
        XCTAssertNoThrow(try RuntimeLaunchGate.validate(installed, outside: []))
    }

    func testRuntimeLaunchGateRejectsMismatchedAndUnapprovedCLIProductTeams() {
        let executableDirectory = URL(
            fileURLWithPath: "/tmp/forge-runtime-signed-cli",
            isDirectory: true
        )
        let executable = executableDirectory.appendingPathComponent("forge-conductor")
        let helper = executableDirectory.appendingPathComponent("forge-runtime-launcher")
        let helperIdentity = RuntimeLaunchGate.CodeIdentity(
            identifier: RuntimeLaunchGate.productIdentifier,
            teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier,
            flags: [],
            uniqueHash: Data(repeating: 0x33, count: 20)
        )

        for team in [RuntimeLaunchGate.distributionTeamIdentifier, "UNAPPROVED1"] {
            XCTAssertThrowsError(
                try RuntimeLaunchGate.validateCommandLineProductIdentity(
                    source: helper,
                    sourceIdentity: helperIdentity,
                    currentExecutable: executable,
                    currentIdentity: RuntimeLaunchGate.CodeIdentity(
                        identifier: "com.forge-conductor.cli",
                        teamIdentifier: team,
                        flags: [],
                        uniqueHash: Data(repeating: 0x34, count: 20)
                    )
                )
            )
        }

        XCTAssertThrowsError(
            try RuntimeLaunchGate.validateCommandLineProductIdentity(
                source: URL(fileURLWithPath: "/tmp/other/forge-runtime-launcher"),
                sourceIdentity: helperIdentity,
                currentExecutable: executable,
                currentIdentity: RuntimeLaunchGate.CodeIdentity(
                    identifier: "com.forge-conductor.cli",
                    teamIdentifier: RuntimeLaunchGate.developmentTeamIdentifier,
                    flags: [],
                    uniqueHash: Data(repeating: 0x35, count: 20)
                )
            )
        )
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

    func testStartupRecoveryPersistsBoundedCleanupDebtWhenProcessGroupDeathIsUnconfirmed() async throws {
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
        try await recoveringService.start()
        let recovered = try await fixture.runtimeRepository.job(jobID)
        XCTAssertEqual(recovered?.state, .failed)
        XCTAssertEqual(recovered?.errorCode, "runtime_termination_unconfirmed")
        XCTAssertTrue(recovered?.errorSummary?.contains("cleanup_debt=true") == true)
        XCTAssertTrue(recovered?.errorSummary?.contains("attempts=1") == true)
        XCTAssertNotNil(recovered?.completedAt)
        let termination = try await fixture.runtimeRepository.terminationRecord(jobID: jobID)
        XCTAssertNil(termination)
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
        XCTAssertEqual(configuredShim.python.executablePath, "/usr/bin/python3")

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

    func testRuntimeInventoryFindsFixedExecutablesWithoutLaunchingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let fallback = root.appendingPathComponent("fallback")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = first.appendingPathComponent("gh")
        let target = fallback.appendingPathComponent("gh")
        try Data("never execute this fixture".utf8).write(to: blocked)
        try Data("never execute this fixture".utf8).write(to: target)
        XCTAssertEqual(Darwin.chmod(blocked.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertEqual(Darwin.chmod(target.path, S_IRWXU), 0)
        let link = first.appendingPathComponent("brew")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let launches = RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue]
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: first.path, capturedAt: "fixture",
            fallbackDirectories: [fallback.path]
        )
        XCTAssertEqual(inventory.executables.map(\.id), RuntimeCapabilityDiscoverer.inventoryExecutableIDs)
        XCTAssertEqual(inventory.executables.count, 13)
        XCTAssertEqual(inventory.pythonPackageAssets.count, 8)
        let gh = try XCTUnwrap(inventory.executables.first { $0.id == "gh" })
        XCTAssertEqual(gh.presence, .present)
        XCTAssertEqual(gh.executable, true)
        XCTAssertEqual(gh.executablePath, RuntimePathCanonicalizer.canonicalExistingURL(target).path)
        XCTAssertEqual(inventory.executables.first { $0.id == "brew" }?.executablePath, gh.executablePath)
        XCTAssertEqual(inventory.executables.first { $0.id == "docker" }?.presence, .notFoundInSearchScope)
        XCTAssertTrue(inventory.executableSearchComplete)
        XCTAssertEqual(RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue], launches)
    }

    func testRuntimeInventoryDistinguishesNonExecutableAndUnresolvableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gh = root.appendingPathComponent("gh")
        try Data("not executable".utf8).write(to: gh)
        XCTAssertEqual(Darwin.chmod(gh.path, S_IRUSR | S_IWUSR), 0)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("brew"), withDestinationURL: root.appendingPathComponent("missing")
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docker"), withIntermediateDirectories: true)
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: root.path, capturedAt: "fixture", fallbackDirectories: []
        )
        XCTAssertEqual(inventory.executables.first { $0.id == "gh" }?.presence, .present)
        XCTAssertEqual(inventory.executables.first { $0.id == "gh" }?.executable, false)
        XCTAssertEqual(inventory.executables.first { $0.id == "brew" }?.presence, .unknown)
        XCTAssertEqual(inventory.executables.first { $0.id == "docker" }?.presence, .unknown)
        XCTAssertEqual(inventory.executables.first { $0.id == "ffmpeg" }?.presence, .notFoundInSearchScope)
        XCTAssertFalse(inventory.executableSearchComplete)
    }

    func testRuntimeInventorySearchBoundsReportUnknownForUnsearchedPaths() {
        let paths = [
            ":relative:/contains\0nul:/" + String(repeating: "x", count: Int(PATH_MAX)),
            (0...RuntimeCapabilityDiscoverer.maximumInventoryPathComponents).map { "/fixture/\($0)" }.joined(separator: ":"),
            "/first:" + String(repeating: "x", count: RuntimeCapabilityDiscoverer.maximumInventorySearchPathBytes),
        ]
        for path in paths {
            let recorder = InventoryObservationRecorder()
            let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
                python: Self.inventoryPython(), searchPath: path, capturedAt: "fixture",
                fallbackDirectories: ["/fallback"], observe: { candidate in recorder.record(candidate); return .missing }
            )
            XCTAssertFalse(inventory.executableSearchComplete)
            XCTAssertTrue(inventory.executables.allSatisfy { $0.presence == .unknown })
            XCTAssertLessThanOrEqual(recorder.paths.count, 13 * 33)
            XCTAssertTrue(recorder.paths.allSatisfy {
                $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count < Int(PATH_MAX)
            })
            XCTAssertFalse(recorder.paths.contains { $0.hasPrefix("/fixture/32/") })
        }
        let partialButFound = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "relative", capturedAt: "fixture",
            fallbackDirectories: ["/fallback"], observe: { candidate in .file(path: candidate, executable: true) }
        )
        XCTAssertFalse(partialButFound.executableSearchComplete)
        XCTAssertTrue(partialButFound.executables.allSatisfy { $0.presence == .present })
    }

    func testRuntimeInventoryDeduplicatesSearchAndCapsFallbackInputs() {
        let recorder = InventoryObservationRecorder()
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "/fixture:/fixture/../fixture:/fixture", capturedAt: "fixture",
            fallbackDirectories: ["/fixture", "/second", "/third", "/fourth", "/fifth", "/sixth", "/omitted"],
            observe: { candidate in recorder.record(candidate); return .missing }
        )
        XCTAssertFalse(inventory.executableSearchComplete)
        XCTAssertEqual(recorder.paths.count, 13 * 6)
        XCTAssertFalse(recorder.paths.contains { $0.hasPrefix("/omitted/") })
        XCTAssertTrue(inventory.executables.allSatisfy { $0.presence == .unknown })
    }

    func testRuntimeInventoryPythonAssetsAreOnlyFilesystemEvidence() throws {
        let interpreter = "/fixture/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        let recorder = InventoryObservationRecorder()
        let launches = RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue]
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(path: interpreter, state: .available), searchPath: nil, capturedAt: "fixture",
            fallbackDirectories: [], observe: { candidate in
                recorder.record(candidate)
                return candidate.hasSuffix("/sqlite3/__init__.py") || candidate.hasSuffix("/PIL/__init__.py")
                    ? .file(path: candidate, executable: false) : .missing
            }
        )
        XCTAssertEqual(inventory.pythonAssetSearchScope, .selectedPythonFramework)
        XCTAssertEqual(inventory.parentRuntimeStatus, .available)
        XCTAssertEqual(inventory.pythonPackageAssets.map(\.id), ["sqlite3", "pip", "Pillow", "python-docx", "openpyxl", "python-pptx", "numpy", "matplotlib"])
        XCTAssertEqual(inventory.pythonPackageAssets.first { $0.id == "Pillow" }?.presence, .present)
        XCTAssertEqual(inventory.pythonPackageAssets.first { $0.id == "pip" }?.presence, .notFoundInSearchScope)
        XCTAssertEqual(recorder.paths.count, 8)
        XCTAssertTrue(recorder.paths.contains("/fixture/Python3.framework/Versions/3.9/lib/python3.9/sqlite3/__init__.py"))
        XCTAssertTrue(recorder.paths.contains("/fixture/Python3.framework/Versions/3.9/lib/python3.9/site-packages/PIL/__init__.py"))
        let result = try RuntimeJobToolPack.capabilitiesResult(Self.inventoryCapabilities(inventory), budget: 65_536)
        let payload = try XCTUnwrap(result.payload["inventory"] as? [String: Any])
        let assets = try XCTUnwrap(payload["python_package_assets"] as? [[String: Any]])
        XCTAssertTrue(assets.allSatisfy { $0["import_verified"] as? Bool == false })
        XCTAssertTrue(assets.allSatisfy { $0["evidence"] as? String == "filesystem_package_asset" })
        XCTAssertEqual(RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue], launches)
    }

    func testRuntimeInventoryUnknownPythonLayoutAndParentFailuresAreNotMissingPackages() {
        let interpreter = "/fixture/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        for python in [
            Self.inventoryPython(path: "/usr/bin/python3", state: .available),
            Self.inventoryPython(path: nil, state: .available),
            Self.inventoryPython(path: interpreter, state: .probeFailed),
            Self.inventoryPython(),
        ] {
            let recorder = InventoryObservationRecorder()
            let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
                python: python, searchPath: nil, capturedAt: "fixture", fallbackDirectories: [],
                observe: { candidate in recorder.record(candidate); return .missing }
            )
            XCTAssertTrue(inventory.pythonPackageAssets.allSatisfy { $0.presence == .unknown && $0.assetPath == nil })
            XCTAssertEqual(inventory.parentRuntimeStatus, python.probeState)
            XCTAssertEqual(inventory.pythonAssetSearchScope, python.available ? .unsupportedLayout : .parentRuntimeUnavailable)
            XCTAssertTrue(recorder.paths.isEmpty)
        }
    }

    func testRuntimeInventoryCanonicalizesPythonFrameworkCurrentBeforeFindingAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let versions = root.appendingPathComponent("Python3.framework/Versions")
        let version = versions.appendingPathComponent("3.12")
        let interpreter = version.appendingPathComponent("Resources/Python.app/Contents/MacOS/Python")
        let asset = version.appendingPathComponent("lib/python3.12/site-packages/pip/__init__.py")
        try FileManager.default.createDirectory(at: interpreter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("must not be launched".utf8).write(to: interpreter)
        try Data("must not be imported".utf8).write(to: asset)
        try FileManager.default.createSymbolicLink(at: versions.appendingPathComponent("Current"), withDestinationURL: version)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = versions.appendingPathComponent("Current/Resources/Python.app/Contents/MacOS/Python")
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(path: current.path, state: .available), searchPath: nil,
            capturedAt: "fixture", fallbackDirectories: []
        )
        XCTAssertEqual(inventory.pythonAssetSearchScope, .selectedPythonFramework)
        XCTAssertEqual(inventory.pythonPackageAssets.first { $0.id == "pip" }?.presence, .present)
        XCTAssertEqual(inventory.pythonPackageAssets.first { $0.id == "pip" }?.assetPath,
                       RuntimePathCanonicalizer.canonicalExistingURL(asset).path)
        XCTAssertEqual(inventory.pythonPackageAssets.first { $0.id == "numpy" }?.presence, .notFoundInSearchScope)
    }

    func testRuntimeInventoryRejectsInvalidCanonicalPathsAndReportsInspectionErrors() {
        for canonical in ["relative", "/contains\0nul", "/" + String(repeating: "x", count: Int(PATH_MAX))] {
            let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
                python: Self.inventoryPython(), searchPath: "/fixture", capturedAt: "fixture",
                fallbackDirectories: [], observe: { _ in .file(path: canonical, executable: true) }
            )
            XCTAssertFalse(inventory.executableSearchComplete)
            XCTAssertTrue(inventory.executables.allSatisfy { $0.presence == .unknown && $0.executablePath == nil })
        }
        let unreadable = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "/fixture", capturedAt: "fixture",
            fallbackDirectories: [], observe: { _ in .unknown }
        )
        XCTAssertFalse(unreadable.executableSearchComplete)
        XCTAssertTrue(unreadable.executables.allSatisfy { $0.presence == .unknown })
    }

    func testRuntimeInventoryCodableRetainsLegacyCapabilitiesAndProbeFallback() throws {
        let legacy = Self.inventoryCapabilities(nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(json["inventory"])
        for key in ["directProcess", "zsh", "bash", "python", "powershell"] {
            var runtime = try XCTUnwrap(json[key] as? [String: Any])
            runtime.removeValue(forKey: "probeState")
            json[key] = runtime
        }
        let decoded = try JSONDecoder().decode(RuntimeCapabilities.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, legacy)
        XCTAssertNil(decoded.inventory)
        XCTAssertTrue(decoded.shellAvailable)
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: nil, capturedAt: "2026-10-07T00:00:00Z", fallbackDirectories: []
        )
        let current = Self.inventoryCapabilities(inventory)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeCapabilities.self, from: JSONEncoder().encode(current)), current)
        XCTAssertEqual(decoded.directProcess, current.directProcess)
        XCTAssertEqual(decoded.python, current.python)
    }

    func testRuntimeInventoryFitsDuplicatedResultAndStrictHTTPIdentifierExample() throws {
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "/fixture", capturedAt: "fixture", fallbackDirectories: [],
            observe: { candidate in .file(path: candidate, executable: true) }
        )
        let result = try RuntimeJobToolPack.capabilitiesResult(Self.inventoryCapabilities(inventory), budget: 65_536)
        XCTAssertEqual(result.payload["inventory_status"] as? String, "included")
        XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: nil, result: result).count, 65_536)
        // HTTP admission caps raw UTF-8 IDs at 256 bytes. Control bytes require
        // six-byte JSON escapes; unbounded legacy stdio IDs are a separate scope.
        let id = String(repeating: "\u{01}", count: 256)
        XCTAssertNotNil(MCPRequestAdmission.Identifier(id, strict: true))
        XCTAssertNil(MCPRequestAdmission.Identifier(id + "x", strict: true))
        XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: id, result: result).count, 65_536)
        let inventoryPayload = try XCTUnwrap(result.payload["inventory"] as? [String: Any])
        let rows = try XCTUnwrap(inventoryPayload["executables"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { $0["probe_state"] as? String == "not_run" && $0["workflow_verified"] as? Bool == false })
    }

    func testRuntimeInventoryBudgetOmissionPreservesUsableLegacyCore() throws {
        let inventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "/fixture", capturedAt: "fixture", fallbackDirectories: [],
            observe: { candidate in .file(path: candidate, executable: true) }
        )
        let capabilities = Self.inventoryCapabilities(inventory)
        var core = try RuntimeJobToolPack.capabilitiesResult(Self.inventoryCapabilities(nil), budget: 65_536).payload
        core.removeValue(forKey: "inventory_status")
        let coreBytes = try MCPToolResponse.data(id: nil, result: .success(core)).count
        let result = try RuntimeJobToolPack.capabilitiesResult(capabilities, budget: coreBytes + 128)
        XCTAssertEqual(result.payload["inventory_status"] as? String, "omitted_inline_budget")
        XCTAssertNil(result.payload["inventory"])
        var retained = result.payload
        retained.removeValue(forKey: "inventory_status")
        XCTAssertEqual(try JSONSupport.canonicalJSON(retained), try JSONSupport.canonicalJSON(core))
        XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: nil, result: result).count, coreBytes + 128)
        let exactLegacy = try RuntimeJobToolPack.capabilitiesResult(capabilities, budget: coreBytes)
        XCTAssertEqual(try JSONSupport.canonicalJSON(exactLegacy.payload), try JSONSupport.canonicalJSON(core))
        XCTAssertThrowsError(try RuntimeJobToolPack.capabilitiesResult(capabilities, budget: coreBytes - 1)) {
            XCTAssertTrue($0.localizedDescription.contains("core metadata exceeds"))
        }
        let escapedComponent = "/" + String(repeating: "\"", count: 200)
        let escapedPath = String(repeating: escapedComponent,
            count: RuntimeCapabilityDiscoverer.maximumInventoryFilePathBytes / escapedComponent.utf8.count)
        XCTAssertLessThanOrEqual(escapedPath.utf8.count, RuntimeCapabilityDiscoverer.maximumInventoryFilePathBytes)
        let oversizedInventory = RuntimeCapabilityDiscoverer.inventorySnapshot(
            python: Self.inventoryPython(), searchPath: "/fixture", capturedAt: "fixture", fallbackDirectories: [],
            observe: { _ in .file(path: escapedPath, executable: true) }
        )
        let omitted = try RuntimeJobToolPack.capabilitiesResult(Self.inventoryCapabilities(oversizedInventory), budget: 65_536)
        XCTAssertEqual(omitted.payload["inventory_status"] as? String, "omitted_inline_budget")
        XCTAssertNil(omitted.payload["inventory"])
        XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: nil, result: omitted).count, 65_536)
        XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "\u{01}", count: 256), result: omitted).count, 65_536)
    }

    func testRuntimeInventoryCachedReadsLeaveShellRequirementsAndShutdownUnchanged() async throws {
        let limits = RuntimeJobLimits(maximumConcurrentJobs: 2, maximumCPUHeavyJobs: 1,
            maximumInlineOutputBytes: 65_536, maximumArtifactBytesPerJob: 131_072)
        let fixture = try await Fixture.make(limits: limits)
        addTeardownBlock { await fixture.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let initial = await fixture.service.capabilities()
        let launches = RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue]
        let pack = RuntimeJobToolPack(service: fixture.service)
        let firstResponse = try await pack.handle(name: "runtime.capabilities", arguments: [:], context: fixture.context)
        let secondResponse = try await pack.handle(name: "runtime.capabilities", arguments: [:], context: fixture.context)
        let first = try XCTUnwrap(firstResponse)
        let second = try XCTUnwrap(secondResponse)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(try JSONSupport.canonicalJSON(first.payload), try JSONSupport.canonicalJSON(second.payload))
        let repeated = await fixture.service.capabilities()
        XCTAssertEqual(repeated, initial)
        XCTAssertNotNil(initial.inventory)
        XCTAssertEqual(RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue], launches)
        let requirements = RuntimeRequirementResolver.resolve(
            input: RuntimeRequirementInput(selectedTools: ["shell_exec"]), capabilities: initial
        )
        XCTAssertFalse(requirements.contains { $0.blocksTask })
        XCTAssertEqual(requirements.first { $0.runtime == .python }?.requirement, .notNeeded)
        let report = await fixture.service.shutdown()
        XCTAssertTrue(report.completed)
        XCTAssertEqual(RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.processLaunches.rawValue], launches)
    }

    private final class InventoryObservationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ path: String) { lock.lock(); defer { lock.unlock() }; values.append(path) }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private static func inventoryPython(
        path: String? = nil, state: RuntimeExecutableProbeState = .unknown
    ) -> RuntimeExecutableCapability {
        RuntimeExecutableCapability(available: state == .available, executablePath: path, required: false, probeState: state)
    }

    private static func inventoryCapabilities(_ inventory: RuntimeCapabilityInventory?) -> RuntimeCapabilities {
        let available = RuntimeExecutableCapability(available: true, executablePath: "/bin/bash", required: true)
        return RuntimeCapabilities(directProcess: available, zsh: available, bash: available,
            python: inventoryPython(), powershell: inventoryPython(), maximumConcurrentJobs: 2,
            maximumCPUHeavyJobs: 1, maximumInlineOutputBytes: 65_536, maximumArtifactBytesPerJob: 131_072,
            maximumArtifactBytesPerProject: 262_144, maximumArtifactBytesGlobal: 524_288,
            maximumRetainedArtifactJobsPerProject: 8, inventory: inventory)
    }

    func testOptionalRuntimeDiscoveryRejectsUnrelatedImmutableExecutables() {
        let capabilities = RuntimeCapabilityDiscoverer(
            configuredPython: URL(fileURLWithPath: "/usr/bin/true"),
            configuredPowerShell: URL(fileURLWithPath: "/usr/bin/true")
        ).discover(limits: Self.testLimits)

        XCTAssertFalse(capabilities.python.available)
        XCTAssertEqual(capabilities.python.executablePath, "/usr/bin/true")
        XCTAssertEqual(capabilities.python.probeState, .probeFailed)
        XCTAssertFalse(capabilities.python.required)
        XCTAssertFalse(capabilities.powershell.available)
        XCTAssertEqual(capabilities.powershell.executablePath, "/usr/bin/true")
        XCTAssertEqual(capabilities.powershell.probeState, .probeFailed)
        XCTAssertFalse(capabilities.powershell.required)
        XCTAssertTrue(capabilities.shellAvailable)
    }

    func testAdvertisedPythonProfileExecutesTheRealInterpreterNatively() async throws {
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

    func testOutsideProjectWorkingDirectoryRunsAndPersists() async throws {
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
        let jobID = try await fixture.service.submit(request)
        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(5)
        )
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        let records = try await fixture.runtimeRepository.list(context: fixture.context)
        XCTAssertEqual(records.map(\.jobID), [jobID])
        await fixture.close()
    }

    func testRuntimeInheritsNativeReadWriteAccessOutsideProjectRoot() async throws {
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
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: outside), Data("overwritten".utf8))
        let output = try await fixture.service.readOutput(
            jobID: jobID,
            stream: .stdout,
            offset: 0,
            limit: 1_024,
            context: fixture.context
        )
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "outside-secret")
        await fixture.close()
    }

    func testEveryAvailableRuntimeProfileInheritsNativeAccessOutsideProject() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["FORGE_NATIVE_ACCESS_SENTINEL"] = "inherited"
        let fixture = try await Fixture.make(environment: environment)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("native-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalFile = outside.appendingPathComponent("external.txt")
        try Data("all-runtime-native-access".utf8).write(to: externalFile)
        let shellScript = "test \"$FORGE_NATIVE_ACCESS_SENTINEL\" = inherited && /bin/ps -p $$ -o pid= >/dev/null && /bin/cat '\(externalFile.path)'"
        let capabilities = await fixture.service.capabilities()
        XCTAssertTrue(capabilities.directProcess.available)
        XCTAssertNil(capabilities.directProcess.executablePath)

        var requests: [(String, RuntimeJobRequest)] = [
            ("process.run", RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["--noprofile", "--norc", "-c", shellScript],
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )),
            ("shell.run", RuntimeJobRequest(
                kind: .shell,
                profile: .zshNoProfile,
                context: fixture.context,
                script: shellScript,
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )),
            ("bash.run", RuntimeJobRequest(
                kind: .bash,
                profile: .bashNoProfile,
                context: fixture.context,
                script: shellScript,
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )),
            ("shell_exec", RuntimeJobRequest(
                kind: .bash,
                profile: .legacyBashLogin,
                context: fixture.context,
                script: shellScript,
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )),
        ]
        if capabilities.python.available {
            requests.append(("python.run", RuntimeJobRequest(
                kind: .python,
                profile: .pythonIsolated,
                context: fixture.context,
                script: "import os,pathlib,subprocess;assert os.environ['FORGE_NATIVE_ACCESS_SENTINEL']=='inherited';subprocess.run(['/bin/ps','-p',str(os.getpid())],check=True,stdout=subprocess.DEVNULL);print(pathlib.Path('\(externalFile.path)').read_text(),end='')",
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )))
        }
        if capabilities.powershell.available {
            requests.append(("powershell.run", RuntimeJobRequest(
                kind: .powershell,
                profile: .powershellNoProfile,
                context: fixture.context,
                script: "if ($env:FORGE_NATIVE_ACCESS_SENTINEL -ne 'inherited') { exit 65 }; & /bin/ps -p $PID -o pid= | Out-Null; [Console]::Out.Write([IO.File]::ReadAllText('\(externalFile.path)'))",
                canonicalWorkingDirectory: outside,
                timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )))
        }

        for (tool, request) in requests {
            let jobID = try await fixture.service.submit(request)
            let record = try await fixture.service.waitForTerminal(
                jobID: jobID,
                context: fixture.context,
                maximumWait: .seconds(8)
            )
            XCTAssertEqual(record.state, .completed, "\(tool): \(record)")
            XCTAssertEqual(record.exitCode, 0, tool)
            let output = try await fixture.service.readOutput(
                jobID: jobID,
                stream: .stdout,
                offset: 0,
                limit: 1_024,
                context: fixture.context
            )
            XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "all-runtime-native-access", tool)
        }
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

    func testRuntimeCanEnumerateSiblingOutsideProjectRoot() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sibling = fixture.root.appendingPathComponent("sibling-secret")
        try Data("sibling".utf8).write(to: sibling, options: .atomic)
        let script = """
        /bin/ls '\(fixture.root.path)'
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
        XCTAssertTrue(String(decoding: output.data, as: UTF8.self).contains("sibling-secret"))
        await fixture.close()
    }

    func testNativeRuntimeDoesNotApplySeatbeltSyscallDenials() async throws {
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
                    "my $pid = fork(); exit 92 unless defined $pid; if ($pid == 0) { exit(POSIX::setsid() == -1 ? 91 : 0); } waitpid($pid, 0); exit($? >> 8);",
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

    func testObservedSetsidSleeperIsReapedAfterNativeParentCompletes() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.projectRoot.appendingPathComponent("setsid-sleeper.pid")
        let program = """
        my $pid = fork();
        exit 90 unless defined $pid;
        if ($pid == 0) {
          exit 91 if POSIX::setsid() == -1;
          open(my $fh, '>', 'setsid-sleeper.pid') or exit 92;
          print $fh "$$\\n";
          close($fh);
          sleep 30;
          exit 0;
        }
        select(undef, undef, undef, 0.75);
        exit 0;
        """
        let jobID = try await fixture.service.submit(
            RuntimeJobRequest(
                kind: .process,
                profile: .directProcess,
                context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-MPOSIX", "-e", program],
                canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(8),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
                replayClass: .readOnly
            )
        )
        let pidFileReady = await Self.waitForFile(pidFile)
        XCTAssertTrue(pidFileReady)
        let descendantPID = try Self.readPID(pidFile)
        let descendantIdentity = try XCTUnwrap(
            RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: descendantPID
            )
        )
        defer {
            if RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: descendantPID
            )?.startIdentity == descendantIdentity.startIdentity {
                _ = Darwin.kill(descendantPID, SIGKILL)
            }
        }

        let record = try await fixture.service.waitForTerminal(
            jobID: jobID,
            context: fixture.context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(record.state, .completed)
        let exactDescendantGone = await Self.waitUntil {
            RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: descendantPID
            )?.startIdentity != descendantIdentity.startIdentity
        }
        XCTAssertTrue(exactDescendantGone, "observed setsid descendant survived terminal cleanup")
        await fixture.close()
    }

    func testDescendantTrackerReportsBudgetOverflowAndRetainsObservedIdentitiesForCleanup() throws {
        let rootIdentity = Self.processIdentity(pid: 101, parent: 1, startMicroseconds: 1)
        let children = [
            Self.processIdentity(pid: 102, parent: 101, startMicroseconds: 2),
            Self.processIdentity(pid: 103, parent: 101, startMicroseconds: 3),
            Self.processIdentity(pid: 104, parent: 101, startMicroseconds: 4),
        ]
        let reader = RuntimeProcessTreeStub(
            identities: Dictionary(uniqueKeysWithValues: ([rootIdentity] + children).map {
                ($0.processIdentifier, $0)
            }),
            children: [101: children.map(\.processIdentifier)]
        )
        let signaler = RuntimeProcessSignalerStub()
        let tracker = RuntimeDescendantTracker(
            rootIdentity: rootIdentity,
            maximumDescendants: 2,
            reader: reader,
            signaler: signaler
        )

        XCTAssertEqual(
            tracker.observe(),
            .limitExceeded(observed: 3, trackingCapacityExceeded: false)
        )
        XCTAssertTrue(tracker.signalTracked(SIGKILL, includeRoot: false))
        XCTAssertEqual(
            signaler.signaledProcessIdentifiers(),
            Set(children.map(\.processIdentifier))
        )
    }

    func testFinalDescendantObservationPreservesHardCapGrowthBetweenCleanupScans() throws {
        let rootIdentity = Self.processIdentity(pid: 501, parent: 1, startMicroseconds: 1)
        let initialChildren = (0..<2).map { index in
            Self.processIdentity(
                pid: Int32(600 + index),
                parent: rootIdentity.processIdentifier,
                startMicroseconds: Int64(index + 2)
            )
        }
        let reader = RuntimeProcessTreeStub(
            identities: Dictionary(uniqueKeysWithValues: ([rootIdentity] + initialChildren).map {
                ($0.processIdentifier, $0)
            }),
            children: [
                rootIdentity.processIdentifier: initialChildren.map(\.processIdentifier),
            ]
        )
        let tracker = RuntimeDescendantTracker(
            rootIdentity: rootIdentity,
            maximumDescendants: 1,
            reader: reader,
            signaler: RuntimeProcessSignalerStub()
        )
        var evidence = ExecutionJobService.RuntimeDescendantLimitEvidence()
        evidence.record(tracker.observe())
        XCTAssertTrue(evidence.exceededLimit)
        XCTAssertFalse(evidence.trackingCapacityExceeded)

        let grownChildren = (0...RuntimeDescendantTracker.maximumTrackedDescendants).map { index in
            Self.processIdentity(
                pid: Int32(1_000 + index),
                parent: rootIdentity.processIdentifier,
                startMicroseconds: Int64(index + 10)
            )
        }
        reader.replace(
            identities: grownChildren,
            children: grownChildren.map(\.processIdentifier),
            of: rootIdentity.processIdentifier
        )
        evidence.record(tracker.observe())

        XCTAssertTrue(evidence.exceededLimit)
        XCTAssertTrue(evidence.trackingCapacityExceeded)
    }

    func testDescendantTrackerExactHardCapWithoutAdditionalChildrenDoesNotOverflow() throws {
        let rootIdentity = Self.processIdentity(pid: 801, parent: 1, startMicroseconds: 1)
        let children = (0..<RuntimeDescendantTracker.maximumTrackedDescendants).map { index in
            Self.processIdentity(
                pid: Int32(2_000 + index),
                parent: rootIdentity.processIdentifier,
                startMicroseconds: Int64(index + 2)
            )
        }
        let reader = RuntimeProcessTreeStub(
            identities: Dictionary(uniqueKeysWithValues: ([rootIdentity] + children).map {
                ($0.processIdentifier, $0)
            }),
            children: [rootIdentity.processIdentifier: children.map(\.processIdentifier)]
        )
        let tracker = RuntimeDescendantTracker(
            rootIdentity: rootIdentity,
            maximumDescendants: RuntimeDescendantTracker.maximumTrackedDescendants,
            reader: reader,
            signaler: RuntimeProcessSignalerStub()
        )

        XCTAssertEqual(
            tracker.observe(),
            .withinLimit(observed: RuntimeDescendantTracker.maximumTrackedDescendants)
        )
    }

    func testDescendantTrackerHardCapPlusOneRemainsExplicitButCannotCreateImmortalLiveness() throws {
        let rootIdentity = Self.processIdentity(pid: 901, parent: 1, startMicroseconds: 1)
        let children = (0..<RuntimeDescendantTracker.maximumTrackedDescendants).map { index in
            Self.processIdentity(
                pid: Int32(1_000 + index),
                parent: rootIdentity.processIdentifier,
                startMicroseconds: Int64(index + 2)
            )
        }
        let untrackedGrandchild = Self.processIdentity(
            pid: 10_000,
            parent: children[0].processIdentifier,
            startMicroseconds: 900_000
        )
        let reader = RuntimeProcessTreeStub(
            identities: Dictionary(uniqueKeysWithValues:
                ([rootIdentity] + children + [untrackedGrandchild]).map {
                ($0.processIdentifier, $0)
            }),
            children: [
                rootIdentity.processIdentifier: children.map(\.processIdentifier),
                children[0].processIdentifier: [untrackedGrandchild.processIdentifier],
            ]
        )
        let signaler = RuntimeProcessSignalerStub()
        let tracker = RuntimeDescendantTracker(
            rootIdentity: rootIdentity,
            maximumDescendants: RuntimeDescendantTracker.maximumTrackedDescendants,
            reader: reader,
            signaler: signaler
        )

        XCTAssertEqual(
            tracker.observe(),
            .limitExceeded(
                observed: RuntimeDescendantTracker.maximumTrackedDescendants,
                trackingCapacityExceeded: true
            )
        )
        XCTAssertTrue(tracker.signalTracked(SIGKILL, includeRoot: true))
        XCTAssertEqual(
            signaler.signaledProcessIdentifiers().count,
            RuntimeDescendantTracker.maximumTrackedDescendants + 1
        )

        reader.removeAllProcesses()
        XCTAssertEqual(
            tracker.observe(),
            .limitExceeded(observed: 0, trackingCapacityExceeded: true)
        )
        XCTAssertFalse(tracker.hasLiveTrackedProcesses(includeRoot: true))
    }

    func testDescendantTrackerNeverSignalsReusedPIDWithMismatchedStartIdentity() throws {
        let rootIdentity = Self.processIdentity(pid: 201, parent: 1, startMicroseconds: 1)
        let childIdentity = Self.processIdentity(pid: 202, parent: 201, startMicroseconds: 2)
        let reader = RuntimeProcessTreeStub(
            identities: [201: rootIdentity, 202: childIdentity],
            children: [201: [202]]
        )
        let signaler = RuntimeProcessSignalerStub()
        let tracker = RuntimeDescendantTracker(
            rootIdentity: rootIdentity,
            maximumDescendants: 4,
            reader: reader,
            signaler: signaler
        )
        XCTAssertEqual(tracker.observe(), .withinLimit(observed: 1))

        reader.replace(
            identity: Self.processIdentity(pid: 202, parent: 1, startMicroseconds: 9),
            children: [],
            of: rootIdentity.processIdentifier
        )
        XCTAssertTrue(tracker.signalTracked(SIGKILL, includeRoot: false))
        XCTAssertTrue(signaler.signaledProcessIdentifiers().isEmpty)
        XCTAssertFalse(tracker.hasLiveTrackedProcesses(includeRoot: false))
    }

    func testNativeRuntimeAllowsPosixSpawnWithNewProcessGroup() async throws {
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
            if (result == EPERM) return 91;
            if (result == 0) {
                kill(-child, SIGKILL);
                waitpid(child, NULL, 0);
                return 0;
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

    func testNativeRuntimeNetworkIsNotRestrictedByLegacyScopeMetadata() async throws {
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
        XCTAssertEqual(deniedRecord.state, .completed)
        XCTAssertEqual(deniedRecord.exitCode, 0)
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

    func testNativeRuntimeCanUseUnixSockets() async throws {
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
        let source = fixture.projectRoot.appendingPathComponent("unix-connect-probe.c")
        let executable = fixture.projectRoot.appendingPathComponent("unix-connect-probe")
        try """
        #include <sys/socket.h>
        #include <sys/un.h>
        #include <string.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
            if (argc != 2) return 64;
            int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
            if (descriptor < 0) return 65;
            struct sockaddr_un address = {0};
            address.sun_family = AF_UNIX;
            if (strlcpy(address.sun_path, argv[1], sizeof(address.sun_path)) >= sizeof(address.sun_path)) return 66;
            int result = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
            close(descriptor);
            return result == 0 ? 0 : 67;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
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
                arguments: [listener.path],
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
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await fixture.close()
    }

    func testNativeRuntimeCanUseSecurityFrameworkBroker() async throws {
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
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.exitCode, 0)
        await fixture.close()
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

    func testSynchronousRuntimeBridgePreservesUserInitiatedTransportPriority() async throws {
        let finished = expectation(description: "user-initiated transport bridge completed")
        let observation = RuntimeBlockingResult<(TaskPriority, TaskPriority, Bool, Bool)>()
        DispatchQueue.global(qos: .userInitiated).async(qos: .userInitiated, flags: .enforceQoS) {
            do {
                let callerPriority = Task.currentPriority
                let callerHasTask = withUnsafeCurrentTask { $0 != nil }
                let worker: (TaskPriority, Bool) = try RuntimeJobSynchronousToolPack.wait(
                    timeoutSeconds: 1,
                    cancellation: nil,
                    committedResultWins: false
                ) {
                    (Task.currentPriority, pthread_main_np() != 0)
                }
                observation.store(.success((callerPriority, worker.0, callerHasTask, worker.1)))
            } catch {
                observation.store(.failure(error))
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 20)
        let observed = try XCTUnwrap(observation.take()).get()
        XCTAssertEqual(observed.0, .userInitiated)
        XCTAssertFalse(observed.2, "The transport control must run outside a Swift task")
        XCTAssertEqual(observed.1, observed.0, "The signalling task must preserve the waiting transport's priority")
        XCTAssertFalse(observed.3, "The detached operation must remain off the main thread")
    }

    func testSynchronousRuntimeBridgePreservesHighPriorityTaskCaller() async throws {
        let finished = expectation(description: "high-priority task bridge completed")
        let observation = RuntimeBlockingResult<(TaskPriority, TaskPriority, Bool, Bool)>()
        let caller = Task.detached(priority: .high) {
            do {
                let callerPriority = Task.currentPriority
                let callerHasTask = withUnsafeCurrentTask { $0 != nil }
                let worker: (TaskPriority, Bool) = try RuntimeJobSynchronousToolPack.wait(
                    timeoutSeconds: 1,
                    cancellation: nil,
                    committedResultWins: false
                ) {
                    (Task.currentPriority, pthread_main_np() != 0)
                }
                observation.store(.success((callerPriority, worker.0, callerHasTask, worker.1)))
            } catch {
                observation.store(.failure(error))
            }
            finished.fulfill()
        }
        defer { caller.cancel() }
        // Observe completion without awaiting caller.value, which would itself
        // introduce a task-priority escalation dependency.
        await fulfillment(of: [finished], timeout: 20)
        let observed = try XCTUnwrap(observation.take()).get()
        XCTAssertEqual(observed.0, .high)
        XCTAssertTrue(observed.2, "This control must execute inside its explicit high-priority task")
        XCTAssertEqual(observed.1, observed.0, "The signalling task must preserve the waiting task's priority")
        XCTAssertFalse(observed.3, "The detached operation must remain off the main thread")
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
        let diagnostic = try XCTUnwrap(fixture.app.diagnostics.recent(limit: 100).last {
            $0.event == "shell_job_terminal"
        })
        XCTAssertNotNil(diagnostic.fields["job_id"])
        XCTAssertEqual(diagnostic.fields["state"], RuntimeJobState.completed.rawValue)
        XCTAssertEqual(diagnostic.fields["terminal"], "true")
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

    func testLegacyShellReportsActualIdempotencyReuse() throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-shell-reuse")
        defer { fixture.close() }
        _ = try fixture.bindProject()
        let arguments: [String: Any] = [
            "command": "printf reused",
            "cwd": fixture.projectRoot.path,
            "idempotency_key": "reused-shell-test",
        ]
        let first = try fixture.app.tools.call(name: "shell_exec", arguments: arguments,
                                               clientID: fixture.clientID)
        let second = try fixture.app.tools.call(name: "shell_exec", arguments: arguments,
                                                clientID: fixture.clientID)
        XCTAssertTrue(first.ok, "\(first.payload)")
        XCTAssertTrue(second.ok, "\(second.payload)")
        let records = fixture.app.diagnostics.recent(limit: 100).filter {
            $0.event == "shell_job_terminal"
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.fields["job_id"], records.last?.fields["job_id"])
        XCTAssertEqual(records.first?.fields["idempotency_match"], "false")
        XCTAssertEqual(records.first?.fields["created_new_job"], "true")
        XCTAssertEqual(records.last?.fields["idempotency_match"], "true")
        XCTAssertEqual(records.last?.fields["created_new_job"], "false")
    }

    func testFailedLegacyShellDiagnosticRetainsJobTerminalState() throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-shell-failure-diagnostic")
        defer { fixture.close() }
        _ = try fixture.bindProject()
        let request = ToolCallCancellation(timeoutSeconds: 10)
        let result = try fixture.app.tools.call(name: "shell_exec", arguments: [
            "command": "exit 7",
            "cwd": fixture.projectRoot.path,
        ], clientID: fixture.clientID, cancellation: request)
        XCTAssertFalse(result.ok)
        let record = try XCTUnwrap(fixture.app.diagnostics.recent(limit: 100).last {
            $0.event == "shell_job_terminal"
        })
        XCTAssertEqual(record.fields["exit_code"], "7")
        XCTAssertEqual(record.fields["state"], RuntimeJobState.failed.rawValue)
        XCTAssertEqual(record.fields["terminal"], "true")
        XCTAssertNotNil(record.fields["job_id"])
        let toolFailure = try XCTUnwrap(fixture.app.diagnostics.recent(limit: 100).last {
            $0.event == "tool_call_failed" && $0.fields["tool"] == "shell_exec"
        })
        XCTAssertEqual(record.fields["invocation_id"], request.requestID.uuidString)
        XCTAssertEqual(toolFailure.fields["invocation_id"], record.fields["invocation_id"])
        XCTAssertNotNil(toolFailure.fields["command_identity"])
        XCTAssertNotNil(toolFailure.fields["cwd_identity"])
        XCTAssertEqual(record.fields["idempotency_match"], "false")
    }

    func testBootstrapRouterLegacyShellExecRetainsNativeAccessOutsideProjectRoot() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-native-legacy-shell")
        defer { fixture.close() }
        let context = try fixture.bindProject()
        let external = fixture.root.appendingPathComponent("owner-authorized-native-shell.txt")
        try Data("native-shell-access".utf8).write(to: external, options: .atomic)
        let quotedExternal = "'" + external.path.replacingOccurrences(
            of: "'",
            with: "'\"'\"'"
        ) + "'"

        let result = try fixture.app.tools.call(
            name: "shell_exec",
            arguments: [
                "command": "/bin/ps -p $$ -o pid= >/dev/null && /bin/cat \(quotedExternal)",
                "cwd": fixture.projectRoot.path,
                "timeout_sec": 5,
            ],
            clientID: fixture.clientID
        )

        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["stdout"] as? String, "native-shell-access")
        XCTAssertEqual((result.payload["exit_code"] as? NSNumber)?.int32Value, 0)
        let jobs = try await fixture.app.runtimeJobs.repository.list(context: context)
        XCTAssertEqual(
            jobs.filter { $0.executionProfile == .legacyBashLogin }.count,
            1
        )
        XCTAssertEqual(
            jobs.first { $0.executionProfile == .legacyBashLogin }?.state,
            .completed
        )
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

    private static func processIdentity(
        pid: Int32,
        parent: Int32,
        startMicroseconds: Int64
    ) -> RuntimeObservedProcessIdentity {
        RuntimeObservedProcessIdentity(
            processIdentifier: pid,
            parentProcessIdentifier: parent,
            processGroupIdentifier: pid,
            startIdentity: RuntimeProcessStartIdentity(
                seconds: 1,
                microseconds: startMicroseconds
            )!
        )
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

    private final class Fixture: Sendable {
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
            terminationRecoveryPolicy:
                ExecutionJobService.RuntimeTerminationRecoveryPolicy? = nil,
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
            _ = try await control.registerProjectUnchecked(
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
            if let terminationRecoveryPolicy {
                try await service.setTerminationRecoveryPolicy(terminationRecoveryPolicy)
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
                let app = try ForgeApp.bootstrap(home: home)
                _ = try app.config.update(["allowed_roots": [root.path]], save: false)
                return ProductionFixture(
                    root: root,
                    projectRoot: project,
                    app: app,
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

    private final class RuntimeProcessTreeStub: RuntimeProcessTreeReading, @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [Int32: RuntimeObservedProcessIdentity]
        private var childrenByParent: [Int32: [Int32]]

        init(
            identities: [Int32: RuntimeObservedProcessIdentity],
            children: [Int32: [Int32]]
        ) {
            self.identities = identities
            childrenByParent = children
        }

        func identity(processIdentifier: Int32) -> RuntimeObservedProcessIdentity? {
            lock.lock()
            defer { lock.unlock() }
            return identities[processIdentifier]
        }

        func children(
            of processIdentifier: Int32,
            maximumCount: Int
        ) -> RuntimeChildProcessList {
            lock.lock()
            defer { lock.unlock() }
            let all = childrenByParent[processIdentifier] ?? []
            return RuntimeChildProcessList(
                processIdentifiers: Array(all.prefix(maximumCount)),
                complete: all.count < maximumCount
            )
        }

        func replace(
            identity: RuntimeObservedProcessIdentity,
            children: [Int32],
            of parentProcessIdentifier: Int32
        ) {
            lock.lock()
            identities[identity.processIdentifier] = identity
            childrenByParent[parentProcessIdentifier] = children
            lock.unlock()
        }

        func replace(
            identities newIdentities: [RuntimeObservedProcessIdentity],
            children: [Int32],
            of parentProcessIdentifier: Int32
        ) {
            lock.lock()
            for identity in newIdentities {
                identities[identity.processIdentifier] = identity
            }
            childrenByParent[parentProcessIdentifier] = children
            lock.unlock()
        }

        func removeAllProcesses() {
            lock.lock()
            identities.removeAll(keepingCapacity: false)
            childrenByParent.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }

    private final class RuntimeProcessSignalerStub: RuntimeProcessSignaling, @unchecked Sendable {
        private let lock = NSLock()
        private var processIdentifiers: Set<Int32> = []

        func signal(processIdentifier: Int32, signal _: Int32) -> Int32 {
            lock.lock()
            processIdentifiers.insert(processIdentifier)
            lock.unlock()
            return 0
        }

        func signaledProcessIdentifiers() -> Set<Int32> {
            lock.lock()
            defer { lock.unlock() }
            return processIdentifiers
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

    func testRawRuntimeIdempotencyRejectsForeignRunAndPreservesSameRunAndLegacyOwner() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let firstRun = try await fixture.autonomousRunContext(mission: "Own raw idempotency receipt")
            let secondRun = try await fixture.autonomousRunContext(mission: "Reject foreign raw idempotency receipt")
            XCTAssertEqual(firstRun.context.projectID, secondRun.context.projectID)
            XCTAssertEqual(firstRun.context.projectGeneration, secondRun.context.projectGeneration)
            XCTAssertNotEqual(firstRun.runID, secondRun.runID)
            XCTAssertNil(fixture.context.runID)
            let arguments: [String: Any] = [
                "executable": "/usr/bin/printf", "arguments": ["raw-receipt"],
                "cwd": fixture.projectRoot.path, "timeout_sec": 5,
                "replay_class": RuntimeReplayClass.readOnly.rawValue,
                "idempotency_key": "raw-run-owner-receipt",
            ]
            let pack = RuntimeJobToolPack(service: fixture.service)
            let submittedOptional = try await pack.handle(name: "process.run", arguments: arguments, context: firstRun.context)
            let submitted = try XCTUnwrap(submittedOptional)
            XCTAssertTrue(submitted.ok, "\(submitted.payload)")
            let firstID = try XCTUnwrap((submitted.payload["job_id"] as? String).flatMap(UUID.init(uuidString:)))
            let terminal = try await fixture.service.waitForTerminal(jobID: firstID, context: firstRun.context, maximumWait: .seconds(8))
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)

            let sameRunOptional = try await pack.handle(name: "process.run", arguments: arguments, context: firstRun.context)
            let sameRun = try XCTUnwrap(sameRunOptional)
            XCTAssertTrue(sameRun.ok, "\(sameRun.payload)")
            XCTAssertEqual(sameRun.payload["job_id"] as? String, firstID.uuidString.lowercased())

            let ownerOptional = try await pack.handle(name: "process.run", arguments: arguments, context: fixture.context)
            let owner = try XCTUnwrap(ownerOptional)
            XCTAssertTrue(owner.ok, "\(owner.payload)")
            XCTAssertEqual(owner.payload["job_id"] as? String, firstID.uuidString.lowercased())

            let foreignReceipt = RuntimeBlockingResult<ToolResult>()
            let foreignPack = RuntimeJobToolPack(service: fixture.service, durableResultObserver: { value in
                foreignReceipt.store(.success(value))
            })
            let foreignOptional = try await foreignPack.handle(name: "process.run", arguments: arguments, context: secondRun.context)
            let foreign = try XCTUnwrap(foreignOptional)
            XCTAssertFalse(foreign.ok, "A foreign run must not receive a successful raw submission: \(foreign.payload)")
            XCTAssertEqual(foreign.payload["code"] as? String, "runtime_job_scope_mismatch")
            XCTAssertNil(foreignReceipt.take(), "A foreign job must not become the committed success receipt")
            do {
                _ = try await fixture.service.status(jobID: firstID, context: secondRun.context)
                XCTFail("The repository must still reject the foreign run's status read")
            } catch let error as RuntimeJobError {
                XCTAssertEqual(error, .jobScopeMismatch(firstID))
            }
            let unchanged = try await fixture.runtimeRepository.job(firstID)
            XCTAssertEqual(unchanged, terminal)
            let foreignRows = try await fixture.service.list(context: secondRun.context)
            let projectRows = try await fixture.service.list(context: fixture.context)
            XCTAssertTrue(foreignRows.isEmpty)
            XCTAssertEqual(projectRows.count, 1)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testRawRuntimeAdmissionRaceRejectsForeignCommittedReceiptBeforePublication() async throws {
        let fixture = try await Fixture.make()
        let admissionClock = RawRuntimeAdmissionClock()
        defer {
            admissionClock.release()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let raceDatabaseURL = await fixture.runtimeRepository.databaseURL
        let raceRepository = try RuntimeJobRepository(databaseURL: raceDatabaseURL, clock: admissionClock)
        let raceService = try ExecutionJobService(
            repository: raceRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(repository: fixture.controlRepository),
            artifactRoot: fixture.root.appendingPathComponent("race-artifacts"), limits: fixture.limits
        )
        try await raceService.start()
        do {
            let firstRun = try await fixture.autonomousRunContext(mission: "Win raw receipt admission")
            let secondRun = try await fixture.autonomousRunContext(mission: "Reject raw receipt admission race")
            XCTAssertEqual(firstRun.context.projectID, secondRun.context.projectID)
            XCTAssertEqual(firstRun.context.projectGeneration, secondRun.context.projectGeneration)
            XCTAssertNotEqual(firstRun.runID, secondRun.runID)
            let key = "raw-raced-owner-receipt"
            let emptyLookup = try await fixture.runtimeRepository.existingJob(
                projectID: fixture.projectID, generation: fixture.context.projectGeneration, idempotencyKey: key
            )
            XCTAssertNil(emptyLookup)
            let arguments: [String: Any] = [
                "executable": "/usr/bin/printf", "arguments": ["must-not-run"],
                "cwd": fixture.projectRoot.path, "timeout_sec": 5,
                "replay_class": RuntimeReplayClass.readOnly.rawValue, "idempotency_key": key,
            ]
            let committedReceipt = RuntimeBlockingResult<ToolResult>()
            let pack = RuntimeJobToolPack(service: raceService, durableResultObserver: { value in
                committedReceipt.store(.success(value))
            })
            let serializedArguments = try SerializedToolArguments(arguments)
            let losingContext = secondRun.context
            admissionClock.arm()
            let admission = Task {
                try await pack.handle(name: "process.run", arguments: try serializedArguments.decoded(), context: losingContext)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            while !admissionClock.didPause(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard admissionClock.didPause() else {
                admissionClock.release()
                admission.cancel()
                _ = try? await admission.value
                XCTFail("The losing admission did not reach the existing createJob clock seam")
                throw RuntimeJobError.storageFailure("runtime receipt race setup failed")
            }
            // createJob's existing injected clock is called after the service's
            // empty lookup and before BEGIN. The independent repository commits
            // a legitimate Run A row before the losing transaction can inspect it.
            let winnerRequest = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: firstRun.context,
                executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["winner"],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                replayClass: .readOnly, idempotencyKey: key
            )
            let winnerID = try await fixture.service.submit(winnerRequest)
            let winner = try await fixture.service.waitForTerminal(
                jobID: winnerID, context: firstRun.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(winner.state, .completed)
            XCTAssertEqual(winner.exitCode, 0)
            XCTAssertEqual(winner.runID, firstRun.runID)
            admissionClock.release()
            let losingOptional = try await admission.value
            XCTAssertFalse(admissionClock.didTimeOut(), "The winner must commit while admission is paused")
            let losing = try XCTUnwrap(losingOptional)
            XCTAssertFalse(losing.ok, "A foreign COMMIT row must not publish success: \(losing.payload)")
            XCTAssertEqual(losing.payload["code"] as? String, "runtime_job_scope_mismatch")
            XCTAssertNil(committedReceipt.take(), "The real pack observer must not expose the foreign COMMIT row")
            let preservedWinner = try await fixture.runtimeRepository.job(winner.jobID)
            XCTAssertEqual(preservedWinner, winner)
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(rows.map(\.jobID), [winner.jobID])

            for allowedContext in [firstRun.context, fixture.context] {
                let retryOptional = try await pack.handle(name: "process.run", arguments: arguments, context: allowedContext)
                let retry = try XCTUnwrap(retryOptional)
                XCTAssertTrue(retry.ok, "Same-run and legacy nil-run owners retain reuse: \(retry.payload)")
                XCTAssertEqual(retry.payload["job_id"] as? String, winner.jobID.uuidString.lowercased())
            }
        } catch {
            admissionClock.release()
            _ = await raceService.shutdown()
            await raceRepository.close()
            await fixture.close()
            throw error
        }
        let stopped = await raceService.shutdown()
        XCTAssertTrue(stopped.completed)
        await raceRepository.close()
        await fixture.close()
    }

    private final class RawRuntimeAdmissionClock: ForgeConductorCore.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private let released = DispatchSemaphore(value: 0)
        private var armed = false
        private var paused = false
        private var timedOut = false

        func arm() { lock.withLock { armed = true } }
        func didPause() -> Bool { lock.withLock { paused } }
        func didTimeOut() -> Bool { lock.withLock { timedOut } }
        func release() { released.signal() }
        func now() -> Date {
            let shouldPause = lock.withLock {
                guard armed else { return false }
                armed = false
                paused = true
                return true
            }
            if shouldPause, released.wait(timeout: .now() + 10) == .timedOut {
                lock.withLock { timedOut = true }
            }
            return Date()
        }
    }


    func testRuntimeRepositoryExistingReceiptUsesExactRunOwnershipAndLegacyOwnerAccess() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let firstRun = try await fixture.autonomousRunContext(mission: "Own repository idempotency receipt")
            let secondRun = try await fixture.autonomousRunContext(mission: "Reject foreign repository idempotency receipt")
            func request(_ context: ToolInvocationContext, key: String) -> RuntimeJobRequest {
                RuntimeJobRequest(
                    kind: .process, profile: .directProcess, context: context,
                    executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["repository-fixture"],
                    canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                    replayClass: .readOnly, idempotencyKey: key
                )
            }
            let key = "repository-owned-receipt"
            let ownerRow = try await fixture.runtimeRepository.createJob(
                jobID: UUID(), request: request(firstRun.context, key: key),
                commandSummary: "repository-owner-fixture", timeoutSeconds: 5, requestArtifactRelativePath: nil
            )
            let foreignObserver = RuntimeBlockingResult<RuntimeJobRecord>()
            do {
                _ = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: request(secondRun.context, key: key),
                    commandSummary: "repository-foreign-fixture", timeoutSeconds: 5, requestArtifactRelativePath: nil,
                    commitObserver: { record in foreignObserver.store(.success(record)) }
                )
                XCTFail("A differing nonnil run must not receive the existing COMMIT row")
            } catch let error as RuntimeJobError {
                XCTAssertEqual(error, .jobScopeMismatch(ownerRow.jobID))
            }
            XCTAssertNil(foreignObserver.take(), "The foreign row must be rejected before the COMMIT observer")
            for allowedContext in [firstRun.context, fixture.context] {
                let allowedObserver = RuntimeBlockingResult<RuntimeJobRecord>()
                let repeated = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: request(allowedContext, key: key),
                    commandSummary: "repository-repeat-fixture", timeoutSeconds: 5, requestArtifactRelativePath: nil,
                    commitObserver: { record in allowedObserver.store(.success(record)) }
                )
                XCTAssertEqual(repeated, ownerRow)
                XCTAssertEqual(try XCTUnwrap(allowedObserver.take()).get(), ownerRow)
            }
            let legacyKey = "repository-legacy-owned-receipt"
            let legacyRow = try await fixture.runtimeRepository.createJob(
                jobID: UUID(), request: request(fixture.context, key: legacyKey),
                commandSummary: "repository-legacy-owner-fixture", timeoutSeconds: 5, requestArtifactRelativePath: nil
            )
            XCTAssertNil(legacyRow.runID)
            let runOwnedObserver = RuntimeBlockingResult<RuntimeJobRecord>()
            do {
                _ = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: request(firstRun.context, key: legacyKey),
                    commandSummary: "repository-run-into-legacy-fixture", timeoutSeconds: 5, requestArtifactRelativePath: nil,
                    commitObserver: { record in runOwnedObserver.store(.success(record)) }
                )
                XCTFail("A run-owned caller must not gain the nil-run project owner's row")
            } catch let error as RuntimeJobError {
                XCTAssertEqual(error, .jobScopeMismatch(legacyRow.jobID))
            }
            XCTAssertNil(runOwnedObserver.take())
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(Set(rows.map(\.jobID)), Set([ownerRow.jobID, legacyRow.jobID]))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }


    func testMCPOutputPagingRoundTripsSplitUnicodeAndInvalidBytesWithoutChangingLegacyFields() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-mcp-lossless-byte-pages")
        defer { fixture.close() }
        let context = try fixture.bindProject()
        let server = MCPServer(app: fixture.app, clientID: fixture.clientID, role: .primary)
        _ = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [:],
                       "clientInfo": ["name": "runtime-output-fixture", "version": "1"]],
        ]))
        var requestID = 2
        func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
            defer { requestID += 1 }
            let response = try XCTUnwrap(server.handle([
                "jsonrpc": "2.0", "id": requestID, "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ]))
            XCTAssertNil(response["error"], "\(response)")
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            let duplicated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(try JSONSupport.canonicalJSON(duplicated), try JSONSupport.canonicalJSON(payload))
            XCTAssertEqual(payload["ok"] as? Bool, true, "\(payload)")
            return payload
        }
        let cases: [(name: String, format: String, expected: Data, limit: Int)] = [
            ("split-unicode", "A🦅Z", Data("A🦅Z".utf8), 2),
            ("whole-unicode", "A🦅Z", Data("A🦅Z".utf8), 5),
            ("ascii", "ASCII", Data("ASCII".utf8), 2),
            ("invalid-native-bytes", "\\377\\376A", Data([0xff, 0xfe, 0x41]), 2),
            ("empty", "", Data(), 2),
        ]
        for item in cases {
            let submission = try call("process.run", arguments: [
                "executable": "/usr/bin/printf", "arguments": [item.format],
                "cwd": fixture.projectRoot.path, "timeout_sec": 5,
                "replay_class": RuntimeReplayClass.readOnly.rawValue,
            ])
            let jobText = try XCTUnwrap(submission["job_id"] as? String)
            let jobID = try XCTUnwrap(UUID(uuidString: jobText))
            let terminal = try await fixture.app.runtimeJobs.service.waitForTerminal(
                jobID: jobID, context: context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed, item.name)
            XCTAssertEqual(terminal.exitCode, 0, item.name)
            var offset: UInt64 = 0
            var reconstructed = Data()
            var reachedEOF = false
            for _ in 0..<32 {
                let page = try call("job.read_output", arguments: [
                    "job_id": jobText, "stream": "stdout", "offset": offset, "limit": item.limit,
                ])
                let legacyText = try XCTUnwrap(page["data"] as? String)
                let returnedOffset = try XCTUnwrap((page["offset"] as? NSNumber)?.uint64Value)
                let next = try XCTUnwrap((page["next_offset"] as? NSNumber)?.uint64Value)
                let retained = try XCTUnwrap((page["retained_bytes"] as? NSNumber)?.uint64Value)
                let observed = try XCTUnwrap((page["observed_bytes"] as? NSNumber)?.uint64Value)
                let eof = try XCTUnwrap(page["eof"] as? Bool)
                let expectedNext = min(offset + UInt64(item.limit), UInt64(item.expected.count))
                XCTAssertEqual(returnedOffset, offset, item.name)
                XCTAssertEqual(next, expectedNext, item.name)
                XCTAssertEqual(retained, UInt64(item.expected.count), item.name)
                XCTAssertEqual(observed, retained, item.name)
                XCTAssertEqual(page["artifact_truncated"] as? Bool, false, item.name)
                XCTAssertEqual(page["sha256"] as? String, JSONSupport.sha256Hex(item.expected), item.name)
                XCTAssertEqual(eof, next == retained, item.name)
                guard next >= offset, next <= UInt64(item.expected.count) else {
                    XCTFail("Nonmonotonic or out-of-range byte page: \(page)")
                    throw RuntimeJobError.invalidRequest("invalid fixture page offsets")
                }
                let expectedPage = Data(item.expected[Int(offset)..<Int(next)])
                XCTAssertEqual(legacyText, String(decoding: expectedPage, as: UTF8.self),
                               "The existing data field retains its legacy decoding: \(item.name)")
                if String(data: expectedPage, encoding: .utf8) != nil {
                    XCTAssertNil(page["data_base64"], "Valid UTF8 pages preserve their existing output shape: \(item.name)")
                    reconstructed.append(contentsOf: legacyText.utf8)
                } else {
                    let lossless = page["data_base64"] as? String
                    XCTAssertNotNil(lossless, "An invalid UTF8 byte page needs a lossless additive representation: \(item.name)")
                    if let lossless, let bytes = Data(base64Encoded: lossless) {
                        XCTAssertEqual(bytes, expectedPage, item.name)
                        XCTAssertLessThanOrEqual(bytes.count, item.limit, item.name)
                        reconstructed.append(bytes)
                    } else {
                        // Preserve a complete baseline failure receipt even when
                        // the old transport has no lossless field.
                        reconstructed.append(contentsOf: legacyText.utf8)
                    }
                }
                if eof { reachedEOF = true; break }
                guard next > offset else {
                    XCTFail("Nonterminal page made no progress: \(page)")
                    throw RuntimeJobError.invalidRequest("fixture page made no progress")
                }
                offset = next
            }
            XCTAssertTrue(reachedEOF, "The bounded byte reader must reach terminal EOF: \(item.name)")
            XCTAssertEqual(reconstructed, item.expected, "Transport must preserve the retained raw bytes: \(item.name)")
        }
    }

    func testManagedRuntimeOutputPagingPreservesBytesWithinCompleteDurableResultBudget() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-managed-byte-budget")
        defer { fixture.close() }
        let projectContext = try fixture.bindProject()
        let repository = fixture.app.projectContexts.repository
        let service = fixture.app.runtimeJobs.service
        let expected = Data(repeating: 0xff, count: 16 * 1_024)
        let format = String(repeating: "\\377", count: expected.count)
        // One argument exactly meets the existing 65536-byte native argument
        // bound. The child writes 16384 actual invalid UTF8 bytes, not text.
        XCTAssertEqual(format.utf8.count, 65_536)
        for budget in [4_096, 65_536] {
            let sessionID = "runtime-byte-budget-\(budget)"
            let rootResponseID = "\(sessionID)-root"
            let run = try await repository.createAutonomousRun(AutonomousRunRequest(
                projectID: projectContext.projectID,
                projectGeneration: projectContext.projectGeneration,
                mission: "Read native byte pages within the intact managed result budget",
                providerID: "runtime-budget-fixture", modelKey: "runtime-budget-fixture",
                specification: AutonomousRunSpecification(
                    allowedTools: RuntimeJobToolPack.names,
                    completionGates: ["lossless-bounded-output"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: projectContext.authorizationScope.canonicalRoots,
                    writableRoots: projectContext.authorizationScope.writableRoots,
                    allowedTools: Set(RuntimeJobToolPack.names), networkAllowed: false,
                    maximumInlineOutputBytes: budget
                )
            ))
            let lease = try await repository.acquireRunLease(
                runID: run.runID, ownerID: sessionID,
                policy: RunLeasePolicy(duration: 120, renewalInterval: 10, maximumDuration: 300)
            )
            try await repository.reserveProviderSession(ProviderSessionIntent(
                sessionID: sessionID, runID: run.runID,
                projectID: run.projectID, projectGeneration: run.projectGeneration,
                providerID: "runtime-budget-fixture", adapterID: "runtime-budget-fixture",
                modelKey: "runtime-budget-fixture", providerResponseID: rootResponseID,
                idempotencyKey: "\(sessionID)-session"
            ), lease: lease)
            let turn = ProviderTurnIntent(
                runID: run.runID, sessionID: sessionID,
                projectID: run.projectID, projectGeneration: run.projectGeneration,
                kind: .normalContinuation, idempotencyKey: "\(sessionID)-turn",
                previousResponseID: rootResponseID,
                inputSHA256: String(repeating: "d", count: 64)
            )
            _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
            let context = try await repository.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID),
                clientID: ClientID(sessionID)
            )
            XCTAssertEqual(context.authorizationScope.maximumInlineOutputBytes, budget)
            XCTAssertEqual(context.runID, run.runID)
            let jobID = try await service.submit(RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: context,
                executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [format],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                maximumInlineOutputBytes: budget, replayClass: .readOnly
            ))
            let terminal = try await service.waitForTerminal(
                jobID: jobID, context: context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            let direct = try await service.readOutput(
                jobID: jobID, stream: .stdout, offset: 0, limit: expected.count, context: context
            )
            XCTAssertEqual(direct.data, expected)
            XCTAssertFalse(direct.artifactTruncated)
            let broker = try ToolInvocationBroker(
                repository: repository, executor: fixture.app.tools,
                classifier: ProductionToolReplayCatalog.classifier(
                    productionToolNames: fixture.app.tools.toolNames
                )
            )
            var offset: UInt64 = 0
            var reconstructed = Data()
            var reachedEOF = false
            var usedShortPage = false
            for pageIndex in 0..<32 {
                let callID = "\(sessionID)-page-\(pageIndex)"
                let call = BrokeredToolCall(
                    providerCallID: callID, toolName: "job.read_output",
                    arguments: ["job_id": jobID.uuidString.lowercased(), "stream": "stdout",
                                "offset": offset, "limit": 16 * 1_024]
                )
                let result: ToolResult
                do {
                    result = try await broker.invoke(
                        call, turnID: turn.turnID, context: context, lease: lease
                    )
                } catch {
                    let rejected = try await repository.toolInvocation(
                        sessionID: sessionID, providerCallID: callID
                    )
                    XCTAssertEqual(rejected?.state, .completed,
                                   "Managed byte page must fit its complete durable result: \(error)")
                    XCTAssertNil(rejected?.lastErrorCode)
                    XCTFail("Actual managed broker rejected the byte page at budget \(budget): \(error)")
                    break
                }
                XCTAssertTrue(result.ok)
                XCTAssertFalse(result.isError)
                let encoded = try JSONSupport.canonicalJSON([
                    "ok": result.ok, "is_error": result.isError, "payload": result.payload,
                ])
                XCTAssertLessThanOrEqual(encoded.utf8.count, min(budget, 65_536))
                let storedValue = try await repository.toolInvocation(
                    sessionID: sessionID, providerCallID: callID
                )
                let stored = try XCTUnwrap(storedValue)
                XCTAssertEqual(stored.state, .completed)
                XCTAssertEqual(stored.resultSummary, encoded)
                XCTAssertEqual(stored.resultSHA256, JSONSupport.sha256Hex(encoded))
                XCTAssertNil(stored.lastErrorCode)
                let page = result.payload
                let returnedOffset = try XCTUnwrap((page["offset"] as? NSNumber)?.uint64Value)
                let next = try XCTUnwrap((page["next_offset"] as? NSNumber)?.uint64Value)
                let retained = try XCTUnwrap((page["retained_bytes"] as? NSNumber)?.uint64Value)
                let observed = try XCTUnwrap((page["observed_bytes"] as? NSNumber)?.uint64Value)
                let eof = try XCTUnwrap(page["eof"] as? Bool)
                XCTAssertEqual(returnedOffset, offset)
                XCTAssertEqual(retained, UInt64(expected.count))
                XCTAssertEqual(observed, retained)
                XCTAssertEqual(page["artifact_truncated"] as? Bool, false)
                XCTAssertEqual(page["sha256"] as? String, JSONSupport.sha256Hex(expected))
                XCTAssertGreaterThan(next, offset)
                XCTAssertLessThanOrEqual(next, min(offset + 16 * 1_024, retained))
                XCTAssertEqual(eof, next == retained)
                guard next > offset, next <= retained else {
                    XCTFail("Returned byte offsets must advance within the retained artifact")
                    break
                }
                let expectedPage = Data(expected[Int(offset)..<Int(next)])
                let legacy = try XCTUnwrap(page["data"] as? String)
                XCTAssertEqual(legacy, String(decoding: expectedPage, as: UTF8.self))
                let lossless = page["data_base64"] as? String
                XCTAssertNotNil(lossless, "Invalid UTF8 page must retain a lossless representation")
                if let lossless, let bytes = Data(base64Encoded: lossless) {
                    XCTAssertEqual(bytes, expectedPage)
                    reconstructed.append(bytes)
                } else {
                    // Retain the complete old-path failure receipt, including
                    // its wrong reconstructed byte count, before proceeding.
                    reconstructed.append(contentsOf: legacy.utf8)
                }
                usedShortPage = usedShortPage || next - offset < 16 * 1_024
                if eof { reachedEOF = true; break }
                offset = next
            }
            XCTAssertTrue(reachedEOF, "The bounded managed reader must reach EOF at budget \(budget)")
            XCTAssertTrue(usedShortPage, "Expanded invalid-byte representations require shorter pages")
            XCTAssertEqual(reconstructed, expected)
            _ = try await repository.releaseRunLease(lease)
        }
    }

    func testManagedRuntimeJobListPreservesCompleteRowsWithinTheDurableResultBudget() async throws {
        let fixture = try ProductionFixture.make(clientName: "runtime-managed-job-list-budget")
        defer { fixture.close() }
        let projectContext = try fixture.bindProject()
        let repository = fixture.app.projectContexts.repository
        let service = fixture.app.runtimeJobs.service
        let budget = 4_096
        let sessionID = "runtime-job-list-budget"
        let rootResponseID = "\(sessionID)-root"
        let run = try await repository.createAutonomousRun(AutonomousRunRequest(
            projectID: projectContext.projectID, projectGeneration: projectContext.projectGeneration,
            mission: "Read native job rows within the intact managed result budget",
            providerID: "runtime-list-budget-fixture", modelKey: "runtime-list-budget-fixture",
            specification: AutonomousRunSpecification(allowedTools: RuntimeJobToolPack.names, completionGates: ["bounded-job-list"]),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: projectContext.authorizationScope.canonicalRoots,
                writableRoots: projectContext.authorizationScope.writableRoots,
                allowedTools: Set(RuntimeJobToolPack.names), networkAllowed: false,
                maximumInlineOutputBytes: budget
            )
        ))
        let lease = try await repository.acquireRunLease(
            runID: run.runID, ownerID: sessionID,
            policy: RunLeasePolicy(duration: 120, renewalInterval: 10, maximumDuration: 300)
        )
        try await repository.reserveProviderSession(ProviderSessionIntent(
            sessionID: sessionID, runID: run.runID, projectID: run.projectID,
            projectGeneration: run.projectGeneration, providerID: "runtime-list-budget-fixture",
            adapterID: "runtime-list-budget-fixture", modelKey: "runtime-list-budget-fixture",
            providerResponseID: rootResponseID, idempotencyKey: "\(sessionID)-session"
        ), lease: lease)
        let turn = ProviderTurnIntent(
            runID: run.runID, sessionID: sessionID, projectID: run.projectID,
            projectGeneration: run.projectGeneration, kind: .normalContinuation,
            idempotencyKey: "\(sessionID)-turn", previousResponseID: rootResponseID,
            inputSHA256: String(repeating: "f", count: 64)
        )
        _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
        let context = try await repository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: sessionID), clientID: ClientID(sessionID)
        )
        XCTAssertEqual(context.runID, run.runID)
        XCTAssertEqual(context.authorizationScope.maximumInlineOutputBytes, budget)
        XCTAssertGreaterThan(projectContext.authorizationScope.maximumInlineOutputBytes, budget)
        var admittedIDs = Set<String>()
        for _ in 0..<6 {
            let jobID = try await service.submit(RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: context,
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                maximumInlineOutputBytes: budget, replayClass: .readOnly
            ))
            let terminal = try await service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(8))
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            XCTAssertEqual(terminal.outputBytes, 0)
            admittedIDs.insert(jobID.uuidString.lowercased())
        }
        XCTAssertEqual(admittedIDs.count, 6)
        let full = try fixture.app.tools.call(
            name: "job.list", arguments: ["states": ["completed"], "limit": 20], context: projectContext
        )
        XCTAssertTrue(full.ok)
        XCTAssertFalse(full.isError)
        let fullRows = try XCTUnwrap(full.payload["jobs"] as? [[String: Any]])
        let fullBytes = try JSONSupport.canonicalJSON(["ok": full.ok, "is_error": full.isError, "payload": full.payload]).utf8.count
        XCTAssertEqual(fullRows.count, 6)
        XCTAssertEqual(full.payload["count"] as? Int, fullRows.count)
        XCTAssertEqual(full.payload["has_more"] as? Bool, false)
        XCTAssertGreaterThan(fullBytes, budget, "The six-row fixture must exercise result expansion, not input admission")
        XCTAssertLessThanOrEqual(fullBytes, projectContext.authorizationScope.maximumInlineOutputBytes)
        let completeByID = try Dictionary(uniqueKeysWithValues: fullRows.map { row in
            (try XCTUnwrap(row["job_id"] as? String), try JSONSupport.canonicalJSON(row))
        })
        XCTAssertEqual(Set(completeByID.keys), admittedIDs)
        let requiredFields: Set<String> = [
            "job_id", "run_id", "project_id", "project_generation", "runtime_kind", "execution_profile",
            "replay_class", "state", "cwd", "command_summary", "timeout_seconds", "exit_code",
            "output_artifact_id", "output_bytes", "process_identifier", "process_group_identifier",
            "error_code", "error_summary", "created_at", "started_at", "completed_at", "updated_at"
        ]
        for row in fullRows {
            XCTAssertTrue(requiredFields.isSubset(of: Set(row.keys)))
            var oneRowPayload = full.payload
            oneRowPayload["jobs"] = [row]
            oneRowPayload["count"] = 1
            oneRowPayload["has_more"] = true
            let oneRowBytes = try JSONSupport.canonicalJSON(["ok": true, "is_error": false, "payload": oneRowPayload]).utf8.count
            XCTAssertLessThanOrEqual(oneRowBytes, budget, "Each complete native record must fit individually")
        }
        let broker = try ToolInvocationBroker(
            repository: repository, executor: fixture.app.tools,
            classifier: ProductionToolReplayCatalog.classifier(productionToolNames: fixture.app.tools.toolNames)
        )
        // Both the existing default of 20 and allowed maximum of 100 must remain useful
        // at a valid smaller managed inline budget without dropping row fields.
        let requests: [[String: Any]] = [["states": ["completed"]], ["states": ["completed"], "limit": 100]]
        for (index, arguments) in requests.enumerated() {
            XCTAssertLessThan(try JSONSupport.canonicalJSON(arguments).utf8.count, budget)
            let call = BrokeredToolCall(providerCallID: "\(sessionID)-list-\(index)", toolName: "job.list", arguments: arguments)
            do {
                let result = try await broker.invoke(call, turnID: turn.turnID, context: context, lease: lease)
                XCTAssertTrue(result.ok)
                XCTAssertFalse(result.isError)
                let encoded = try JSONSupport.canonicalJSON(["ok": result.ok, "is_error": result.isError, "payload": result.payload])
                XCTAssertLessThanOrEqual(encoded.utf8.count, budget)
                let storedValue = try await repository.toolInvocation(sessionID: sessionID, providerCallID: call.providerCallID)
                let stored = try XCTUnwrap(storedValue)
                XCTAssertEqual(stored.state, .completed)
                XCTAssertEqual(stored.resultSummary, encoded)
                XCTAssertEqual(stored.resultSHA256, JSONSupport.sha256Hex(encoded))
                XCTAssertNil(stored.lastErrorCode)
                let rows = try XCTUnwrap(result.payload["jobs"] as? [[String: Any]])
                XCTAssertFalse(rows.isEmpty, "An individually fitting full record must remain readable")
                XCTAssertLessThanOrEqual(rows.count, fullRows.count)
                XCTAssertEqual(result.payload["count"] as? Int, rows.count)
                XCTAssertEqual(result.payload["has_more"] as? Bool, rows.count < fullRows.count)
                var returnedIDs = Set<String>()
                for row in rows {
                    let id = try XCTUnwrap(row["job_id"] as? String)
                    XCTAssertTrue(returnedIDs.insert(id).inserted)
                    XCTAssertTrue(requiredFields.isSubset(of: Set(row.keys)))
                    XCTAssertEqual(try JSONSupport.canonicalJSON(row), completeByID[id], "Budgeting must preserve the complete existing row contract")
                }
            } catch {
                let stored = try await repository.toolInvocation(sessionID: sessionID, providerCallID: call.providerCallID)
                XCTAssertEqual(stored?.state, .completed, "Valid job.list request left an ambiguous result: \(error)")
                XCTAssertNil(stored?.lastErrorCode)
                XCTFail("Actual managed job.list rejected six native terminal rows at budget \(budget), default/maximum request \(index), full bytes \(fullBytes): \(error)")
            }
            let unchanged = try await service.list(context: context, limit: 20)
            XCTAssertEqual(Set(unchanged.map { $0.jobID.uuidString.lowercased() }), admittedIDs)
            XCTAssertTrue(unchanged.allSatisfy { $0.state == .completed && $0.exitCode == 0 })
        }
        var cursor: [String: Any] = [:]
        var pagedIDs = Set<String>()
        var reachedEnd = false
        for page in 0..<7 {
            var arguments: [String: Any] = ["states": ["completed"], "limit": 100]
            arguments.merge(cursor) { _, new in new }
            let result = try await broker.invoke(BrokeredToolCall(
                providerCallID: "\(sessionID)-page-\(page)", toolName: "job.list", arguments: arguments
            ), turnID: turn.turnID, context: context, lease: lease)
            XCTAssertTrue(result.ok)
            let encoded = try JSONSupport.canonicalJSON(["ok": result.ok, "is_error": result.isError, "payload": result.payload])
            XCTAssertLessThanOrEqual(encoded.utf8.count, budget)
            let rows = try XCTUnwrap(result.payload["jobs"] as? [[String: Any]])
            for row in rows {
                let id = try XCTUnwrap(row["job_id"] as? String)
                XCTAssertTrue(pagedIDs.insert(id).inserted, "Cursor pages must not repeat a job")
                XCTAssertEqual(try JSONSupport.canonicalJSON(row), completeByID[id])
            }
            if result.payload["has_more"] as? Bool == false {
                reachedEnd = true
                XCTAssertNil(result.payload["next_cursor"])
                break
            }
            XCTAssertFalse(rows.isEmpty)
            cursor = try XCTUnwrap(result.payload["next_cursor"] as? [String: Any])
            XCTAssertEqual(Set(cursor.keys), ["before_created_at", "before_job_id"])
            XCTAssertEqual(cursor["before_created_at"] as? String, rows.last?["created_at"] as? String)
            XCTAssertEqual(cursor["before_job_id"] as? String, rows.last?["job_id"] as? String)
        }
        XCTAssertTrue(reachedEnd, "Six complete jobs must be traversable within seven bounded pages")
        XCTAssertEqual(pagedIDs, admittedIDs)
        _ = try await repository.releaseRunLease(lease)
    }

    func testRuntimeJobListCursorPreservesTimestampTiesAndLegacyExclusiveTimeFilter() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let repository = try RuntimeJobRepository(databaseURL: databaseURL,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
        do {
            let request = RuntimeJobRequest(kind: .process, profile: .directProcess,
                context: fixture.context, executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(5), replayClass: .readOnly)
            var all = Set<UUID>()
            for _ in 0..<6 {
                let id = UUID()
                _ = try await repository.createJob(jobID: id, request: request,
                    commandSummary: "Owned unlaunched cursor fixture", timeoutSeconds: 5,
                    requestArtifactRelativePath: nil)
                all.insert(id)
            }
            let first = try await repository.list(context: fixture.context, limit: 2)
            XCTAssertEqual(first.count, 2)
            let timestamp = try XCTUnwrap(first.last?.createdAt)
            XCTAssertTrue(first.allSatisfy { $0.createdAt == timestamp })
            let legacy = try await repository.list(context: fixture.context, limit: 100,
                beforeCreatedAt: timestamp)
            XCTAssertTrue(legacy.isEmpty, "Existing timestamp-only cursors retain their exclusive semantics")
            var cursor: UUID?
            var seen = Set<UUID>()
            for _ in 0..<4 {
                let page = try await repository.list(context: fixture.context, limit: 2,
                    beforeCreatedAt: cursor == nil ? nil : timestamp, beforeJobID: cursor)
                for row in page {
                    XCTAssertEqual(row.createdAt, timestamp)
                    XCTAssertTrue(seen.insert(row.jobID).inserted)
                }
                if page.isEmpty { break }
                cursor = page.last?.jobID
            }
            XCTAssertEqual(seen, all, "The UUID tie-breaker must retain every equal-timestamp row")
            do {
                _ = try await repository.list(context: fixture.context, beforeJobID: UUID())
                XCTFail("An unpaired cursor must be rejected at its repository boundary")
            } catch let error as RuntimeJobError {
                guard case .invalidRequest = error else { throw error }
            }
            await repository.close()
            await fixture.close()
        } catch {
            await repository.close()
            await fixture.close()
            throw error
        }
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

extension RuntimeExecutionJobTests {
    private enum PreCommitAdmissionFixtureError: Error, Equatable, Sendable {
        case rejected
        case alreadyConsumed
        case barrierTimedOut
    }

    func testPreCommitAdmissionPersistsSeparateSourceReceiptBeforeControlPlaneCommit() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let source = try SQLiteStore(path: fixture.root.appendingPathComponent("admission-source.sqlite"))
        defer { source.close() }
        let jobID = UUID()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let admitted = RuntimeBlockingResult<RuntimeJobRecord>()
        let committed = RuntimeBlockingResult<RuntimeJobRecord>()
        let callback: RuntimeJobPreCommitAdmission = { record in
            guard admitted.take() == nil else { throw PreCommitAdmissionFixtureError.alreadyConsumed }
            try source.memorySet(key: "native-admission", body: record.jobID.uuidString.lowercased())
            admitted.store(.success(record))
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw PreCommitAdmissionFixtureError.barrierTimedOut
            }
        }
        let request = Self.preCommitRequest(fixture: fixture, admission: callback)
        let create = Task.detached(priority: .utility) {
            try await fixture.runtimeRepository.createJob(
                jobID: jobID, request: request, commandSummary: "pre-commit ordering fixture",
                timeoutSeconds: 5, requestArtifactRelativePath: nil,
                preCommitAdmission: callback,
                commitObserver: { record in committed.store(.success(record)) }
            )
        }
        do {
            let didEnter = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
                }
            }
            XCTAssertTrue(didEnter, "The bounded barrier must pause inside admission")
            let observed = try XCTUnwrap(admitted.take()).get()
            XCTAssertEqual(observed.jobID, jobID)
            XCTAssertEqual(observed.projectID, fixture.projectID)
            XCTAssertEqual(observed.projectGeneration, fixture.context.projectGeneration)
            XCTAssertEqual(observed.state, .queued)
            let beforeCommit = try await Task.detached(priority: .utility) {
                (
                    try Self.sqliteCount(databaseURL: databaseURL,
                        sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                        textBinding: jobID.uuidString.lowercased()),
                    try source.memoryGet(key: "native-admission")
                )
            }.value
            XCTAssertEqual(beforeCommit.0, 0, "A separate CP reader must not see the uncommitted job")
            XCTAssertEqual(beforeCommit.1, jobID.uuidString.lowercased())
            XCTAssertNil(committed.take(), "The existing persistence observer must remain after COMMIT")
            release.signal()
            let stored = try await create.value
            XCTAssertEqual(stored, observed)
            XCTAssertEqual(try XCTUnwrap(committed.take()).get(), stored)
            let visible = try await Task.detached(priority: .utility) {
                try Self.sqliteCount(databaseURL: databaseURL,
                    sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id=?",
                    textBinding: jobID.uuidString.lowercased())
            }.value
            XCTAssertEqual(visible, 1)
        } catch {
            release.signal()
            create.cancel()
            _ = await create.result
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionThrowRollsBackJobWithoutErasingSeparateSourceReceipt() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let sourceURL = fixture.root.appendingPathComponent("admission-source.sqlite")
        let source = try SQLiteStore(path: sourceURL)
        defer { source.close() }
        let jobID = UUID()
        let committed = RuntimeBlockingResult<RuntimeJobRecord>()
        let callback: RuntimeJobPreCommitAdmission = { record in
            guard try source.memoryGet(key: "consumed-native-admission") == nil else {
                throw PreCommitAdmissionFixtureError.alreadyConsumed
            }
            try source.memorySet(key: "consumed-native-admission", body: record.jobID.uuidString.lowercased())
            throw PreCommitAdmissionFixtureError.rejected
        }
        let request = Self.preCommitRequest(fixture: fixture, admission: callback,
            idempotencyKey: "rolled-back-native-admission")
        do {
            for expectedError in [PreCommitAdmissionFixtureError.rejected, .alreadyConsumed] {
                do {
                    _ = try await fixture.runtimeRepository.createJob(
                        jobID: jobID, request: request, commandSummary: "rollback fixture",
                        timeoutSeconds: 5, requestArtifactRelativePath: nil,
                        preCommitAdmission: callback,
                        commitObserver: { record in committed.store(.success(record)) }
                    )
                    XCTFail("A throwing Source admission must not commit a CP job")
                } catch let error as PreCommitAdmissionFixtureError {
                    XCTAssertEqual(error, expectedError)
                }
            }
            XCTAssertNil(committed.take())
            let rows = try await Task.detached(priority: .utility) {
                try Self.sqliteCount(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM execution_jobs")
            }.value
            XCTAssertEqual(rows, 0)
            let existing = try await fixture.runtimeRepository.existingJob(
                projectID: fixture.projectID, generation: fixture.context.projectGeneration,
                idempotencyKey: "rolled-back-native-admission"
            )
            XCTAssertNil(existing)
            source.close()
            let reopenedReceipt = try await Task.detached(priority: .utility) {
                let reopened = try SQLiteStore(path: sourceURL)
                defer { reopened.close() }
                return try reopened.memoryGet(key: "consumed-native-admission")
            }.value
            XCTAssertEqual(reopenedReceipt, jobID.uuidString.lowercased())
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionCancellationAfterSourceCommitRollsBackOnlyControlPlaneJob() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let source = try SQLiteStore(path: fixture.root.appendingPathComponent("admission-source.sqlite"))
        defer { source.close() }
        let jobID = UUID()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let committed = RuntimeBlockingResult<RuntimeJobRecord>()
        let callback: RuntimeJobPreCommitAdmission = { record in
            try source.memorySet(key: "cancelled-native-admission", body: record.jobID.uuidString.lowercased())
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw PreCommitAdmissionFixtureError.barrierTimedOut
            }
        }
        let request = Self.preCommitRequest(fixture: fixture, admission: callback)
        let create = Task.detached(priority: .utility) {
            try await fixture.runtimeRepository.createJob(
                jobID: jobID, request: request, commandSummary: "cancelled admission fixture",
                timeoutSeconds: 5, requestArtifactRelativePath: nil,
                preCommitAdmission: callback,
                commitObserver: { record in committed.store(.success(record)) }
            )
        }
        do {
            let didEnter = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: entered.wait(timeout: .now() + 2) == .success)
                }
            }
            XCTAssertTrue(didEnter)
            create.cancel()
            release.signal()
            do {
                _ = try await create.value
                XCTFail("Cancellation after Source admission must still prevent CP COMMIT")
            } catch is CancellationError {
                // The repository checks cancellation after admission and before COMMIT.
            }
            XCTAssertNil(committed.take())
            let observed = try await Task.detached(priority: .utility) {
                (
                    try Self.sqliteCount(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM execution_jobs"),
                    try source.memoryGet(key: "cancelled-native-admission")
                )
            }.value
            XCTAssertEqual(observed.0, 0)
            XCTAssertEqual(observed.1, jobID.uuidString.lowercased())
        } catch {
            release.signal()
            create.cancel()
            _ = await create.result
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionNewAndEarlyReusedJobReceivesActualNativeRecordWithoutReplay() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.projectRoot.appendingPathComponent("admitted-once")
        let key = "ordinary-precommit-once"
        let firstAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
        let firstCommit = RuntimeBlockingResult<RuntimeJobRecord>()
        let firstCallback: RuntimeJobPreCommitAdmission = { record in
            guard firstAdmission.take() == nil else { throw PreCommitAdmissionFixtureError.alreadyConsumed }
            firstAdmission.store(.success(record))
        }
        do {
            let original = try await fixture.service.submitWithOutcome(Self.preCommitRequest(
                fixture: fixture, executable: "/usr/bin/touch", arguments: [marker.path],
                admission: firstCallback, idempotencyKey: key,
                persistenceObserver: { record in firstCommit.store(.success(record)) }
            ))
            XCTAssertFalse(original.reused)
            let admitted = try XCTUnwrap(firstAdmission.take()).get()
            XCTAssertEqual(admitted.jobID, original.jobID)
            XCTAssertEqual(admitted.state, .queued)
            XCTAssertEqual(try XCTUnwrap(firstCommit.take()).get(), admitted)
            let terminal = try await fixture.service.waitForTerminal(
                jobID: original.jobID, context: fixture.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

            let reusedAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
            let reusedCommit = RuntimeBlockingResult<RuntimeJobRecord>()
            let replacement = try await fixture.service.submitWithOutcome(Self.preCommitRequest(
                fixture: fixture, executable: "/bin/rm", arguments: [marker.path],
                admission: { record in
                    guard reusedAdmission.take() == nil else { throw PreCommitAdmissionFixtureError.alreadyConsumed }
                    reusedAdmission.store(.success(record))
                }, idempotencyKey: key,
                persistenceObserver: { record in reusedCommit.store(.success(record)) }
            ))
            XCTAssertTrue(replacement.reused)
            XCTAssertEqual(replacement.jobID, original.jobID)
            XCTAssertEqual(try XCTUnwrap(reusedAdmission.take()).get(), terminal)
            XCTAssertEqual(try XCTUnwrap(reusedCommit.take()).get(), terminal)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Early reuse must not execute the replacement command")
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(rows.map(\.jobID), [original.jobID])
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionCompactedReceiptIsAdmittedByEarlyAndTransactionalReuseWithoutReplay() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let marker = fixture.projectRoot.appendingPathComponent("compacted-admitted-once")
        let key = "ordinary-precommit-compacted"
        do {
            let original = try await fixture.service.submit(Self.preCommitRequest(
                fixture: fixture, executable: "/usr/bin/touch", arguments: [marker.path],
                admission: nil, idempotencyKey: key
            ))
            let terminal = try await fixture.service.waitForTerminal(
                jobID: original, context: fixture.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            let newer = try await fixture.service.submit(Self.preCommitRequest(fixture: fixture, admission: nil))
            let newerTerminal = try await fixture.service.waitForTerminal(
                jobID: newer, context: fixture.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(newerTerminal.state, .completed)
            let compacted = try await fixture.runtimeRepository.compactTerminalJobs(
                maximumPerProject: 100, maximumGlobal: 1,
                maximumIdempotencyReceiptsPerProject: 2, maximumIdempotencyReceiptsGlobal: 2
            )
            XCTAssertEqual(compacted, 1)
            let receipt = try await fixture.runtimeRepository.existingJob(
                projectID: fixture.projectID, generation: fixture.context.projectGeneration,
                idempotencyKey: key
            )
            let expected = try XCTUnwrap(receipt)
            XCTAssertEqual(expected.jobID, original)
            XCTAssertEqual(expected.state, .completed)
            XCTAssertNil(expected.processIdentifier)
            let earlyAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
            let earlyCommit = RuntimeBlockingResult<RuntimeJobRecord>()
            let reused = try await fixture.service.submitWithOutcome(Self.preCommitRequest(
                fixture: fixture, executable: "/bin/rm", arguments: [marker.path],
                admission: { record in earlyAdmission.store(.success(record)) }, idempotencyKey: key,
                persistenceObserver: { record in earlyCommit.store(.success(record)) }
            ))
            XCTAssertTrue(reused.reused)
            XCTAssertEqual(reused.jobID, original)
            XCTAssertEqual(try XCTUnwrap(earlyAdmission.take()).get(), expected)
            XCTAssertEqual(try XCTUnwrap(earlyCommit.take()).get(), expected)

            let candidateID = UUID()
            let transactionalAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
            let transactionalCommit = RuntimeBlockingResult<RuntimeJobRecord>()
            let callback: RuntimeJobPreCommitAdmission = { record in
                transactionalAdmission.store(.success(record))
            }
            let transactionallyReused = try await fixture.runtimeRepository.createJob(
                jobID: candidateID, request: Self.preCommitRequest(fixture: fixture,
                    executable: "/bin/rm", arguments: [marker.path], admission: callback, idempotencyKey: key),
                commandSummary: "must reuse compacted receipt", timeoutSeconds: 5,
                requestArtifactRelativePath: nil, preCommitAdmission: callback,
                commitObserver: { record in transactionalCommit.store(.success(record)) }
            )
            XCTAssertEqual(transactionallyReused, expected)
            XCTAssertEqual(try XCTUnwrap(transactionalAdmission.take()).get(), expected)
            XCTAssertEqual(try XCTUnwrap(transactionalCommit.take()).get(), expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            let counts = try await Task.detached(priority: .utility) {
                (
                    try Self.sqliteCount(databaseURL: databaseURL,
                        sql: "SELECT COUNT(*) FROM execution_jobs WHERE job_id IN (?,?)",
                        textBindings: [original.uuidString.lowercased(), candidateID.uuidString.lowercased()]),
                    try Self.sqliteCount(databaseURL: databaseURL,
                        sql: "SELECT COUNT(*) FROM runtime_job_idempotency_receipts WHERE job_id=?",
                        textBinding: original.uuidString.lowercased())
                )
            }.value
            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 1)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionRaceAdmitsCommittedWinnerAndDiscardsReplacementCommand() async throws {
        let fixture = try await Fixture.make()
        let admissionClock = RawRuntimeAdmissionClock()
        defer {
            admissionClock.release()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let raceRepository = try RuntimeJobRepository(databaseURL: databaseURL, clock: admissionClock)
        let raceService = try ExecutionJobService(
            repository: raceRepository,
            contextValidator: ProjectControlPlaneRuntimeJobContextValidator(repository: fixture.controlRepository),
            artifactRoot: fixture.root.appendingPathComponent("precommit-race-artifacts"), limits: fixture.limits
        )
        let marker = fixture.projectRoot.appendingPathComponent("race-winner")
        let key = "ordinary-precommit-raced-key"
        let admitted = RuntimeBlockingResult<RuntimeJobRecord>()
        let committed = RuntimeBlockingResult<RuntimeJobRecord>()
        let request = Self.preCommitRequest(fixture: fixture, executable: "/bin/rm",
            arguments: [marker.path], admission: { record in admitted.store(.success(record)) },
            idempotencyKey: key, persistenceObserver: { record in committed.store(.success(record)) })
        var submission: Task<(jobID: UUID, reused: Bool), Error>?
        do {
            try await raceService.start()
            admissionClock.arm()
            let losing = Task.detached(priority: .utility) { try await raceService.submitWithOutcome(request) }
            submission = losing
            for _ in 0..<200 {
                if admissionClock.didPause() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(admissionClock.didPause(), "The race must pause after the empty early lookup")
            XCTAssertNil(admitted.take(), "An empty early lookup must not consume admission")
            let winner = try await fixture.service.submit(Self.preCommitRequest(
                fixture: fixture, executable: "/usr/bin/touch", arguments: [marker.path],
                admission: nil, idempotencyKey: key
            ))
            let terminal = try await fixture.service.waitForTerminal(
                jobID: winner, context: fixture.context, maximumWait: .seconds(5)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            admissionClock.release()
            let reused = try await losing.value
            XCTAssertTrue(reused.reused)
            XCTAssertEqual(reused.jobID, winner)
            XCTAssertEqual(try XCTUnwrap(admitted.take()).get(), terminal)
            XCTAssertEqual(try XCTUnwrap(committed.take()).get(), terminal)
            XCTAssertFalse(admissionClock.didTimeOut())
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(rows.map(\.jobID), [winner])
        } catch {
            admissionClock.release()
            submission?.cancel()
            if let submission { _ = await submission.result }
            await raceService.shutdown()
            await raceRepository.close()
            await fixture.close()
            throw error
        }
        await raceService.shutdown()
        await raceRepository.close()
        await fixture.close()
    }

    func testPreCommitAdmissionRechecksRevokedSwitchedAndResetContextsInsideRepositoryTransaction() async throws {
        for change in 0..<4 {
            let fixture = try await Fixture.make()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let databaseURL = await fixture.runtimeRepository.databaseURL
            let admitted = RuntimeBlockingResult<RuntimeJobRecord>()
            let committed = RuntimeBlockingResult<RuntimeJobRecord>()
            let callback: RuntimeJobPreCommitAdmission = { record in admitted.store(.success(record)) }
            let request = Self.preCommitRequest(fixture: fixture, admission: callback,
                idempotencyKey: "binding-fence-existing-job")
            do {
                let owner = ProjectBindingOwner(kind: .mcpClient, id: fixture.context.clientID.rawValue)
                try await fixture.controlRepository.validate(fixture.context, for: owner)
                let original = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: request, commandSummary: "existing public nil-path fixture",
                    timeoutSeconds: 5, requestArtifactRelativePath: nil
                )
                XCTAssertNil(admitted.take(), "The public createJob overload must keep its nil-admission contract")
                let expectedError: ProjectContextError
                switch change {
                case 0:
                    let changed = try await Task.detached(priority: .utility) {
                        try Self.updatePreCommitFixture(databaseURL: databaseURL,
                            sql: "UPDATE project_bindings SET active=0 WHERE owner_kind=? AND owner_id=? AND active=1",
                            textBindings: [owner.kind.rawValue, owner.id])
                    }.value
                    XCTAssertEqual(changed, 1)
                    expectedError = .projectContextRequired(owner)
                case 1:
                    let otherRoot = fixture.root.appendingPathComponent("other-project", isDirectory: true)
                    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
                    let otherID = ProjectID()
                    _ = try await fixture.controlRepository.registerProjectUnchecked(
                        projectID: otherID, displayName: "Switched Admission Fixture", canonicalRoot: otherRoot
                    )
                    let changed = try await Task.detached(priority: .utility) {
                        try Self.updatePreCommitFixture(databaseURL: databaseURL,
                            sql: "UPDATE project_bindings SET project_id=? WHERE owner_kind=? AND owner_id=? AND active=1",
                            textBindings: [otherID.description, owner.kind.rawValue, owner.id])
                    }.value
                    XCTAssertEqual(changed, 1)
                    expectedError = .projectScopeMismatch
                case 2:
                    _ = try await fixture.controlRepository.beginReset(
                        projectID: fixture.projectID, expectedGeneration: fixture.context.projectGeneration
                    )
                    expectedError = .projectNotActive(.resetting)
                default:
                    _ = try await fixture.controlRepository.beginReset(
                        projectID: fixture.projectID, expectedGeneration: fixture.context.projectGeneration
                    )
                    let reset = try await fixture.controlRepository.completeReset(
                        projectID: fixture.projectID, expectedGeneration: fixture.context.projectGeneration
                    )
                    expectedError = .staleProjectGeneration(expected: fixture.context.projectGeneration,
                        actual: reset.newGeneration)
                }
                do {
                    _ = try await fixture.runtimeRepository.createJob(
                        jobID: UUID(), request: request, commandSummary: "stale native admission",
                        timeoutSeconds: 5, requestArtifactRelativePath: nil, preCommitAdmission: callback,
                        commitObserver: { record in committed.store(.success(record)) }
                    )
                    XCTFail("Earlier caller validation must not authorize a changed CP binding")
                } catch let error as ProjectContextError {
                    XCTAssertEqual(error, expectedError)
                }
                do {
                    _ = try await fixture.runtimeRepository.admitExistingJob(
                        request: request, preCommitAdmission: callback,
                        commitObserver: { record in committed.store(.success(record)) }
                    )
                    XCTFail("The early reuse transaction must recheck the same changed CP binding")
                } catch let error as ProjectContextError {
                    XCTAssertEqual(error, expectedError)
                }
                XCTAssertNil(admitted.take())
                XCTAssertNil(committed.take())
                let count = try await Task.detached(priority: .utility) {
                    try Self.sqliteCount(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM execution_jobs")
                }.value
                XCTAssertEqual(count, 1)
                let unchanged = try await fixture.runtimeRepository.job(original.jobID)
                XCTAssertEqual(unchanged, original)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }

    func testPreCommitAdmissionRequiresAllScopeFieldsAndDecodesLegacyStoredWritableRoots() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = await fixture.runtimeRepository.databaseURL
        let scope = fixture.context.authorizationScope
        let owner = ProjectBindingOwner(kind: .mcpClient, id: fixture.context.clientID.rawValue)
        let admitted = RuntimeBlockingResult<RuntimeJobRecord>()
        let callback: RuntimeJobPreCommitAdmission = { record in admitted.store(.success(record)) }
        do {
            let legacyScope = String(decoding: try JSONSerialization.data(withJSONObject: [
                "canonicalRoots": scope.canonicalRoots.map(\.path),
                "allowedTools": scope.allowedTools.sorted(),
                "networkAllowed": scope.networkAllowed,
                "maximumInlineOutputBytes": scope.maximumInlineOutputBytes,
            ], options: [.sortedKeys]), as: UTF8.self)
            let changed = try await Task.detached(priority: .utility) {
                try Self.updatePreCommitFixture(databaseURL: databaseURL,
                    sql: "UPDATE project_bindings SET authorization_scope_json=? WHERE owner_kind=? AND owner_id=? AND active=1",
                    textBindings: [legacyScope, owner.kind.rawValue, owner.id])
            }.value
            XCTAssertEqual(changed, 1)
            let original = try await fixture.runtimeRepository.createJob(
                jobID: UUID(), request: Self.preCommitRequest(fixture: fixture, admission: callback),
                commandSummary: "legacy scope admission", timeoutSeconds: 5,
                requestArtifactRelativePath: nil, preCommitAdmission: callback
            )
            XCTAssertEqual(try XCTUnwrap(admitted.take()).get(), original)
            let mismatchedScopes = [
                ToolAuthorizationScope(canonicalRoots: [fixture.root], writableRoots: scope.writableRoots,
                    allowedTools: scope.allowedTools, networkAllowed: scope.networkAllowed,
                    maximumInlineOutputBytes: scope.maximumInlineOutputBytes),
                ToolAuthorizationScope(canonicalRoots: scope.canonicalRoots, writableRoots: [],
                    allowedTools: scope.allowedTools, networkAllowed: scope.networkAllowed,
                    maximumInlineOutputBytes: scope.maximumInlineOutputBytes),
                ToolAuthorizationScope(canonicalRoots: scope.canonicalRoots, writableRoots: scope.writableRoots,
                    allowedTools: ["job.status"], networkAllowed: scope.networkAllowed,
                    maximumInlineOutputBytes: scope.maximumInlineOutputBytes),
                ToolAuthorizationScope(canonicalRoots: scope.canonicalRoots, writableRoots: scope.writableRoots,
                    allowedTools: scope.allowedTools, networkAllowed: !scope.networkAllowed,
                    maximumInlineOutputBytes: scope.maximumInlineOutputBytes),
                ToolAuthorizationScope(canonicalRoots: scope.canonicalRoots, writableRoots: scope.writableRoots,
                    allowedTools: scope.allowedTools, networkAllowed: scope.networkAllowed,
                    maximumInlineOutputBytes: scope.maximumInlineOutputBytes + 1),
            ]
            for mismatched in mismatchedScopes {
                let context = ToolInvocationContext(projectID: fixture.projectID,
                    projectGeneration: fixture.context.projectGeneration, clientID: fixture.context.clientID,
                    authorizationScope: mismatched)
                let rejectedAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
                let rejectedCommit = RuntimeBlockingResult<RuntimeJobRecord>()
                let rejectCallback: RuntimeJobPreCommitAdmission = { record in rejectedAdmission.store(.success(record)) }
                do {
                    _ = try await fixture.runtimeRepository.createJob(
                        jobID: UUID(), request: Self.preCommitRequest(fixture: fixture,
                            context: context, admission: rejectCallback),
                        commandSummary: "mismatched scope fixture", timeoutSeconds: 5,
                        requestArtifactRelativePath: nil, preCommitAdmission: rejectCallback,
                        commitObserver: { record in rejectedCommit.store(.success(record)) }
                    )
                    XCTFail("Every stored scope field must match before admission")
                } catch let error as ProjectContextError {
                    XCTAssertEqual(error, .projectScopeMismatch)
                }
                XCTAssertNil(rejectedAdmission.take())
                XCTAssertNil(rejectedCommit.take())
            }
            let narrowedStoredScope = String(decoding: try JSONSerialization.data(withJSONObject: [
                "canonicalRoots": scope.canonicalRoots.map(\.path),
                "writableRoots": scope.writableRoots.map(\.path),
                "allowedTools": ["job.status"],
                "networkAllowed": scope.networkAllowed,
                "maximumInlineOutputBytes": scope.maximumInlineOutputBytes,
            ], options: [.sortedKeys]), as: UTF8.self)
            _ = try await Task.detached(priority: .utility) {
                try Self.updatePreCommitFixture(databaseURL: databaseURL,
                    sql: "UPDATE project_bindings SET authorization_scope_json=? WHERE owner_kind=? AND owner_id=? AND active=1",
                    textBindings: [narrowedStoredScope, owner.kind.rawValue, owner.id])
            }.value
            let narrowedAdmission = RuntimeBlockingResult<RuntimeJobRecord>()
            let narrowedCallback: RuntimeJobPreCommitAdmission = { record in narrowedAdmission.store(.success(record)) }
            do {
                _ = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: Self.preCommitRequest(fixture: fixture, admission: narrowedCallback),
                    commandSummary: "changed stored tools fixture", timeoutSeconds: 5,
                    requestArtifactRelativePath: nil, preCommitAdmission: narrowedCallback
                )
                XCTFail("A previously broader context must not pass the current stored allowed tools")
            } catch let error as ProjectContextError {
                XCTAssertEqual(error, .projectScopeMismatch)
            }
            XCTAssertNil(narrowedAdmission.take())
            let rows = try await Task.detached(priority: .utility) {
                try Self.sqliteCount(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM execution_jobs")
            }.value
            XCTAssertEqual(rows, 1)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionRejectsManagedProviderAndRuntimeIdentityWhilePublicRequestKeepsNilPath() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let run = try await fixture.autonomousRunContext(mission: "Preserve non-admitted managed runtime jobs")
            let publicRequest = RuntimeJobRequest(kind: .process, profile: .directProcess,
                context: run.context, executable: URL(fileURLWithPath: "/usr/bin/true"),
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes, replayClass: .readOnly)
            XCTAssertNil(publicRequest.preCommitAdmission)
            let jobID = try await fixture.service.submit(publicRequest)
            let terminal = try await fixture.service.waitForTerminal(
                jobID: jobID, context: run.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            XCTAssertEqual(terminal.runID, run.runID)
            let nonOrdinary = [
                run.context,
                ToolInvocationContext(projectID: fixture.projectID,
                    projectGeneration: fixture.context.projectGeneration, clientID: fixture.context.clientID,
                    providerSessionID: "native-provider-test", authorizationScope: fixture.context.authorizationScope),
                ToolInvocationContext(projectID: fixture.projectID,
                    projectGeneration: fixture.context.projectGeneration, clientID: fixture.context.clientID,
                    runtimeJobID: jobID, authorizationScope: fixture.context.authorizationScope),
            ]
            for context in nonOrdinary {
                let admitted = RuntimeBlockingResult<RuntimeJobRecord>()
                let committed = RuntimeBlockingResult<RuntimeJobRecord>()
                let callback: RuntimeJobPreCommitAdmission = { record in admitted.store(.success(record)) }
                do {
                    _ = try await fixture.runtimeRepository.createJob(
                        jobID: UUID(), request: Self.preCommitRequest(fixture: fixture,
                            context: context, admission: callback),
                        commandSummary: "nonordinary admission fixture", timeoutSeconds: 5,
                        requestArtifactRelativePath: nil, preCommitAdmission: callback,
                        commitObserver: { record in committed.store(.success(record)) }
                    )
                    XCTFail("A nonnil ordinary continuity admission must reject another native identity")
                } catch let error as ProjectContextError {
                    XCTAssertEqual(error, .projectScopeMismatch)
                }
                XCTAssertNil(admitted.take())
                XCTAssertNil(committed.take())
            }
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(rows.map(\.jobID), [jobID])
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    func testPreCommitAdmissionFailureDuringBothReusePathsPreservesCommittedJobAndSourceReceipt() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try SQLiteStore(path: fixture.root.appendingPathComponent("admission-source.sqlite"))
        defer { source.close() }
        let marker = fixture.projectRoot.appendingPathComponent("reuse-admission-failed")
        let key = "ordinary-precommit-reuse-failure"
        let committed = RuntimeBlockingResult<RuntimeJobRecord>()
        let callback: RuntimeJobPreCommitAdmission = { record in
            guard try source.memoryGet(key: "failed-reuse-admission") == nil else {
                throw PreCommitAdmissionFixtureError.alreadyConsumed
            }
            try source.memorySet(key: "failed-reuse-admission", body: record.jobID.uuidString.lowercased())
            throw PreCommitAdmissionFixtureError.rejected
        }
        do {
            let original = try await fixture.service.submit(Self.preCommitRequest(
                fixture: fixture, executable: "/usr/bin/touch", arguments: [marker.path],
                admission: nil, idempotencyKey: key
            ))
            let terminal = try await fixture.service.waitForTerminal(
                jobID: original, context: fixture.context, maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            let replacement = Self.preCommitRequest(fixture: fixture, executable: "/bin/rm",
                arguments: [marker.path], admission: callback, idempotencyKey: key,
                persistenceObserver: { record in committed.store(.success(record)) })
            do {
                _ = try await fixture.service.submitWithOutcome(replacement)
                XCTFail("Throwing early reuse admission must propagate its failure")
            } catch let error as PreCommitAdmissionFixtureError {
                XCTAssertEqual(error, .rejected)
            }
            do {
                _ = try await fixture.runtimeRepository.createJob(
                    jobID: UUID(), request: replacement, commandSummary: "rejected transactional reuse",
                    timeoutSeconds: 5, requestArtifactRelativePath: nil, preCommitAdmission: callback,
                    commitObserver: { record in committed.store(.success(record)) }
                )
                XCTFail("Transactional reuse must not undo a separately consumed admission")
            } catch let error as PreCommitAdmissionFixtureError {
                XCTAssertEqual(error, .alreadyConsumed)
            }
            XCTAssertNil(committed.take())
            let unchanged = try await fixture.runtimeRepository.job(original)
            XCTAssertEqual(unchanged, terminal)
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertEqual(rows.map(\.jobID), [original])
            let receipt = try await Task.detached(priority: .utility) {
                try source.memoryGet(key: "failed-reuse-admission")
            }.value
            XCTAssertEqual(receipt, original.uuidString.lowercased())
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private static func preCommitRequest(
        fixture: Fixture,
        context: ToolInvocationContext? = nil,
        executable: String = "/usr/bin/true",
        arguments: [String] = [],
        admission: RuntimeJobPreCommitAdmission?,
        idempotencyKey: String? = nil,
        persistenceObserver: (@Sendable (RuntimeJobRecord) -> Void)? = nil
    ) -> RuntimeJobRequest {
        RuntimeJobRequest(kind: .process, profile: .directProcess, context: context ?? fixture.context,
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes, replayClass: .idempotent,
            idempotencyKey: idempotencyKey, fileSizeProfile: .standard,
            preCommitAdmission: admission, persistenceObserver: persistenceObserver)
    }

    private static func updatePreCommitFixture(
        databaseURL: URL,
        sql: String,
        textBindings: [String]
    ) throws -> Int {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeJobError.storageFailure("could not open pre-commit SQLite fixture")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_busy_timeout(database, 1_000) == SQLITE_OK else {
            throw RuntimeJobError.storageFailure("could not bound pre-commit fixture update")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure("could not prepare pre-commit fixture update")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in textBindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                throw RuntimeJobError.storageFailure("could not bind pre-commit fixture update")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RuntimeJobError.storageFailure("could not apply pre-commit fixture update")
        }
        return Int(sqlite3_changes(database))
    }
}

extension RuntimeExecutionJobTests {
    private struct SharedOwnerObserver: Sendable {
        let control: ProjectControlPlaneRepository
        let repository: RuntimeJobRepository
        let service: ExecutionJobService

        static func make(fixture: Fixture) async throws -> Self {
            let database = await fixture.runtimeRepository.databaseURL
            let control = try ProjectControlPlaneRepository(databaseURL: database)
            let repository = try RuntimeJobRepository(databaseURL: database)
            let service = try ExecutionJobService(
                repository: repository,
                contextValidator: ProjectControlPlaneRuntimeJobContextValidator(repository: control),
                artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
                limits: fixture.limits
            )
            return Self(control: control, repository: repository, service: service)
        }

        func close() async {
            _ = await service.shutdown()
            await repository.close()
            await control.close()
        }
    }

    func testShutdownCannotReportCompletionWhenDurableOwnershipInspectionFails() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await fixture.runtimeRepository.close()
        let report = await fixture.service.shutdown()
        XCTAssertFalse(report.completed, "An unreadable ledger is not proof that no jobs remain")
        XCTAssertTrue(report.unresolvedJobIDs.isEmpty, "An inspection error must not invent a job UUID")
        XCTAssertTrue(report.persistencePendingJobIDs.isEmpty)
    }

    private enum SharedOwnerPreparationError: Error, Sendable {
        case alreadyEntered
        case timedOut
    }

    private actor SharedOwnerPreparationGate {
        private var pausedJobID: UUID?
        private var released = false
        private var waiter: CheckedContinuation<Void, Error>?
        private var timeout: Task<Void, Never>?

        func pause(jobID: UUID) async throws {
            guard pausedJobID == nil else { throw SharedOwnerPreparationError.alreadyEntered }
            pausedJobID = jobID
            if released { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    await self?.expire()
                }
            }
        }

        func observedJobID() -> UUID? { pausedJobID }

        func release() {
            released = true
            timeout?.cancel()
            timeout = nil
            let waiting = waiter
            waiter = nil
            waiting?.resume()
        }

        private func expire() {
            timeout = nil
            let waiting = waiter
            waiter = nil
            waiting?.resume(throwing: SharedOwnerPreparationError.timedOut)
        }
    }

    private struct SharedOwnerPreparationValidator: RuntimeJobContextValidating {
        let base: ProjectControlPlaneRuntimeJobContextValidator
        let gate: SharedOwnerPreparationGate

        func validateCaller(_ context: ToolInvocationContext) async throws {
            try await base.validateCaller(context)
        }

        func prepareJob(jobID: UUID, context: ToolInvocationContext) async throws -> ToolInvocationContext {
            try await base.validateCaller(context)
            try await gate.pause(jobID: jobID)
            return try await base.prepareJob(jobID: jobID, context: context)
        }

        func contextForStoredJob(jobID: UUID) async throws -> ToolInvocationContext {
            try await base.contextForStoredJob(jobID: jobID)
        }

        func validateJob(jobID: UUID, context: ToolInvocationContext) async throws {
            try await base.validateJob(jobID: jobID, context: context)
        }

        func commitJobResult(jobID: UUID, context: ToolInvocationContext, resultSHA256: String) async throws {
            try await base.commitJobResult(jobID: jobID, context: context, resultSHA256: resultSHA256)
        }
    }

    private static func sharedOwnerSleepRequest(fixture: Fixture) -> RuntimeJobRequest {
        RuntimeJobRequest(
            kind: .process, profile: .directProcess, context: fixture.context,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'owned-live-stdout\\n'; printf 'owned-live-stderr\\n' >&2; exec /bin/sleep 30"],
            canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(40),
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes,
            replayClass: .readOnly
        )
    }

    func testSecondRuntimeServicePreservesLiveOwnerIdentityOutputAndIndependentShutdown() async throws {
        let fixture = try await Fixture.make()
        let observer = try await SharedOwnerObserver.make(fixture: fixture)
        addTeardownBlock {
            await fixture.close()
            await observer.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let jobID = try await fixture.service.submit(Self.sharedOwnerSleepRequest(fixture: fixture))
        let ready = await Self.waitUntil {
            let stdout = try? await fixture.service.readOutput(
                jobID: jobID, stream: .stdout, offset: 0, limit: 1024, context: fixture.context)
            let stderr = try? await fixture.service.readOutput(
                jobID: jobID, stream: .stderr, offset: 0, limit: 1024, context: fixture.context)
            return stdout?.data == Data("owned-live-stdout\n".utf8)
                && stderr?.data == Data("owned-live-stderr\n".utf8)
                && stdout?.jobState == .running && stderr?.jobState == .running
        }
        XCTAssertTrue(ready)
        let before = try await fixture.service.status(jobID: jobID, context: fixture.context)
        let beforeIdentityValue = try await fixture.runtimeRepository.recoveryProcessIdentity(jobID: jobID)
        let beforeIdentity = try XCTUnwrap(beforeIdentityValue)
        let beforeObserved = RuntimeProcessIdentityReader.observedIdentity(
            processIdentifier: beforeIdentity.processIdentifier)
        XCTAssertEqual(before.state, .running)
        XCTAssertNil(before.errorCode)
        XCTAssertEqual(beforeObserved?.startIdentity, beforeIdentity.startIdentity)
        XCTAssertEqual(beforeObserved?.parentProcessIdentifier, Darwin.getpid())
        let stdoutBefore = try await fixture.service.readOutput(
            jobID: jobID, stream: .stdout, offset: 0, limit: 1024, context: fixture.context)
        let stderrBefore = try await fixture.service.readOutput(
            jobID: jobID, stream: .stderr, offset: 0, limit: 1024, context: fixture.context)
        XCTAssertTrue(stdoutBefore.isSnapshot)
        XCTAssertTrue(stderrBefore.isSnapshot)
        XCTAssertNil(stdoutBefore.producerEndReason)
        XCTAssertNil(stderrBefore.producerEndReason)

        try await observer.service.start()
        let after = try await observer.service.status(jobID: jobID, context: fixture.context)
        let afterIdentity = try await observer.repository.recoveryProcessIdentity(jobID: jobID)
        let afterObserved = RuntimeProcessIdentityReader.observedIdentity(
            processIdentifier: beforeIdentity.processIdentifier)
        XCTAssertEqual(after.state, .running, "Another service must not recover a live owner's row")
        XCTAssertNil(after.errorCode)
        XCTAssertEqual(after.processIdentifier, before.processIdentifier)
        XCTAssertEqual(after.processGroupIdentifier, before.processGroupIdentifier)
        XCTAssertEqual(afterIdentity, beforeIdentity)
        XCTAssertEqual(afterObserved?.startIdentity, beforeIdentity.startIdentity)
        XCTAssertEqual(afterObserved?.parentProcessIdentifier, Darwin.getpid())
        for (stream, expected) in [(RuntimeOutputStream.stdout, stdoutBefore), (.stderr, stderrBefore)] {
            do {
                let output = try await fixture.service.readOutput(
                    jobID: jobID, stream: stream, offset: 0, limit: 1024, context: fixture.context)
                XCTAssertEqual(output, expected, "A second service must preserve the full owner-spool snapshot")
            } catch {
                XCTFail("Live owner output became unavailable after another service started: \(error)")
            }
        }
        let observerShutdown = await observer.service.shutdown()
        XCTAssertTrue(observerShutdown.completed, "A nonowning service must close independently of a live owner")
        XCTAssertTrue(observerShutdown.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(observerShutdown.persistencePendingJobIDs.isEmpty)
        let stillRunning = try await fixture.service.status(jobID: jobID, context: fixture.context)
        XCTAssertEqual(stillRunning.state, .running)
        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let cancelled = try await fixture.service.waitForTerminal(
            jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(cancelled.state, .cancelled)
        let ownerShutdown = await fixture.service.shutdown()
        XCTAssertTrue(ownerShutdown.completed)
    }

    func testSecondRuntimeServicePreservesCommittedQueuedIntentBeforeJobPreparation() async throws {
        let fixture = try await Fixture.make()
        let initialShutdown = await fixture.service.shutdown()
        XCTAssertTrue(initialShutdown.completed)
        let gate = SharedOwnerPreparationGate()
        let owner = try ExecutionJobService(
            repository: fixture.runtimeRepository,
            contextValidator: SharedOwnerPreparationValidator(
                base: ProjectControlPlaneRuntimeJobContextValidator(repository: fixture.controlRepository),
                gate: gate),
            artifactRoot: fixture.root.appendingPathComponent("artifacts", isDirectory: true),
            limits: fixture.limits
        )
        try await owner.start()
        let observer = try await SharedOwnerObserver.make(fixture: fixture)
        let marker = fixture.projectRoot.appendingPathComponent("queued-live-owner-marker")
        let request = fixture.request(
            kind: .bash, profile: .bashNoProfile,
            script: "printf 'QUEUED-OWNER-ONCE\\n' >> queued-live-owner-marker; printf 'queued-owner-output\\n'",
            timeout: 5, replayClass: .nonReplayable)
        let submission = Task { try await owner.submit(request) }
        addTeardownBlock {
            await gate.release()
            submission.cancel()
            _ = await submission.result
            _ = await owner.shutdown()
            await observer.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let paused = await Self.waitUntil { await gate.observedJobID() != nil }
        XCTAssertTrue(paused)
        let pausedID = await gate.observedJobID()
        let jobID = try XCTUnwrap(pausedID)
        let beforeValue = try await fixture.runtimeRepository.job(jobID)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.state, .queued)
        XCTAssertNil(before.processIdentifier)
        let requestPathValue = try await fixture.runtimeRepository.requestArtifactRelativePath(jobID: jobID)
        let requestPath = try XCTUnwrap(requestPathValue)
        let requestURL = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(requestPath)
        let stagedBytes = try Data(contentsOf: requestURL)
        XCTAssertFalse(stagedBytes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try await observer.service.start()
        let afterValue = try await observer.repository.job(jobID)
        let afterPath = try await observer.repository.requestArtifactRelativePath(jobID: jobID)
        XCTAssertEqual(afterValue, before, "A live queued intent must not be terminalized as an owner restart")
        XCTAssertEqual(afterPath, requestPath)
        XCTAssertEqual(try? Data(contentsOf: requestURL), stagedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let observerShutdown = await observer.service.shutdown()
        XCTAssertTrue(observerShutdown.completed)
        XCTAssertTrue(observerShutdown.unresolvedJobIDs.isEmpty)

        await gate.release()
        let acceptedID = try await submission.value
        XCTAssertEqual(acceptedID, jobID)
        let completed = try await owner.waitForTerminal(
            jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.exitCode, 0)
        XCTAssertNil(completed.errorCode)
        XCTAssertEqual(try? String(contentsOf: marker, encoding: .utf8), "QUEUED-OWNER-ONCE\n")
        do {
            let output = try await owner.readOutput(
                jobID: jobID, stream: .stdout, offset: 0, limit: 1024, context: fixture.context)
            XCTAssertEqual(output.data, Data("queued-owner-output\n".utf8))
            XCTAssertFalse(output.isSnapshot)
            XCTAssertEqual(output.producerEndReason, .eof)
            XCTAssertNil(output.producerReadErrno)
            XCTAssertFalse(output.artifactTruncated)
        } catch {
            XCTFail("The preserved queued intent must produce its one completed output: \(error)")
        }
        let ownerShutdown = await owner.shutdown()
        XCTAssertTrue(ownerShutdown.completed)
    }

    func testAnotherAuthorizedRuntimeServiceCancellationReachesLiveOwnerAndFinalOutput() async throws {
        let fixture = try await Fixture.make()
        let observer = try await SharedOwnerObserver.make(fixture: fixture)
        addTeardownBlock {
            await fixture.close()
            await observer.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        // Start the nonowner before submission so startup recovery cannot cause
        // the cancellation outcome this independent case measures.
        try await observer.service.start()
        let jobID = try await fixture.service.submit(Self.sharedOwnerSleepRequest(fixture: fixture))
        let ready = await Self.waitUntil {
            let stdout = try? await fixture.service.readOutput(
                jobID: jobID, stream: .stdout, offset: 0, limit: 1024, context: fixture.context)
            let stderr = try? await fixture.service.readOutput(
                jobID: jobID, stream: .stderr, offset: 0, limit: 1024, context: fixture.context)
            return stdout?.data == Data("owned-live-stdout\n".utf8)
                && stderr?.data == Data("owned-live-stderr\n".utf8)
                && stdout?.jobState == .running && stderr?.jobState == .running
        }
        XCTAssertTrue(ready)
        let before = try await fixture.service.status(jobID: jobID, context: fixture.context)
        XCTAssertEqual(before.state, .running)
        try await observer.service.cancel(jobID: jobID, context: fixture.context)
        let fromOtherService = try await fixture.service.waitForTerminal(
            jobID: jobID, context: fixture.context, maximumWait: .seconds(2))
        XCTAssertEqual(fromOtherService.state, .cancelled,
            "A persisted cancellation must reach the actual owner without a second caller cancellation")
        XCTAssertNotEqual(fromOtherService.errorCode, "runtime_owner_restarted")
        for (stream, expected) in [(RuntimeOutputStream.stdout, Data("owned-live-stdout\n".utf8)),
                                   (.stderr, Data("owned-live-stderr\n".utf8))] {
            let output = try await fixture.service.readOutput(
                jobID: jobID, stream: stream, offset: 0, limit: 1024, context: fixture.context)
            XCTAssertEqual(output.data, expected)
            XCTAssertEqual(output.sha256, JSONSupport.sha256Hex(expected))
            XCTAssertFalse(output.isSnapshot)
            XCTAssertEqual(output.jobState, .cancelled)
            XCTAssertTrue(output.eof)
            XCTAssertEqual(output.producerEndReason, .eof)
            XCTAssertNil(output.producerReadErrno)
            XCTAssertFalse(output.artifactTruncated)
        }
        // This cleanup remains owner-local even when the foreign cancellation
        // assertion fails, so the real sleep never escapes the owned fixture.
        try await fixture.service.cancel(jobID: jobID, context: fixture.context)
        let cleanup = try await fixture.service.waitForTerminal(
            jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
        XCTAssertEqual(cleanup.state, .cancelled)
        let ownerShutdown = await fixture.service.shutdown()
        let observerShutdown = await observer.service.shutdown()
        XCTAssertTrue(ownerShutdown.completed)
        XCTAssertTrue(observerShutdown.completed)
    }

    private struct WarmOrphanIntent: Sendable {
        let record: RuntimeJobRecord
        let outputDirectory: URL
        let requestDirectory: URL
        let marker: URL
    }

    private actor WarmRecoveredIdentityProbe: RuntimeRecoveredProcessControlling {
        struct Event: Equatable, Sendable {
            let signal: Int32
            let identity: RuntimePersistedProcessIdentity
        }
        private var events: [Event] = []

        func signalProcessGroup(
            _ signal: Int32, expectedIdentity: RuntimePersistedProcessIdentity
        ) async -> RuntimeRecoveredProcessSignalResult {
            guard events.count < 64 else { return .identityUnavailable }
            events.append(Event(signal: signal, identity: expectedIdentity))
            return .processMissing
        }

        func observed() -> [Event] { events }
    }

    private static func insertWarmOrphanIntent(
        fixture: Fixture,
        context: ToolInvocationContext? = nil,
        state: RuntimeJobState = .queued,
        startIdentity: RuntimeProcessStartIdentity? = nil
    ) async throws -> WarmOrphanIntent {
        let scope = context ?? fixture.context
        let workingDirectory = try XCTUnwrap(scope.authorizationScope.canonicalRoots.first)
        let jobID = UUID()
        let marker = workingDirectory.appendingPathComponent("warm-must-not-replay-" + jobID.uuidString)
        let script = "printf 'must-not-replay' > " + marker.lastPathComponent
        let relative = [scope.projectID.description, String(scope.projectGeneration.rawValue),
                        jobID.uuidString.lowercased()].joined(separator: "/")
        let artifacts = fixture.root.appendingPathComponent("artifacts", isDirectory: true)
        let outputDirectory = artifacts.appendingPathComponent(relative, isDirectory: true)
        let requestRelative = ".runtime-scratch/" + relative + "/request.bash"
        let requestURL = artifacts.appendingPathComponent(requestRelative)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("uncommitted-partial-output".utf8).write(to: outputDirectory.appendingPathComponent("stdout.log"))
        try Data(script.utf8).write(to: requestURL)
        let request = RuntimeJobRequest(kind: .bash, profile: .bashNoProfile, context: scope,
            script: script, canonicalWorkingDirectory: workingDirectory, timeout: .seconds(5),
            maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes, replayClass: .nonReplayable)
        _ = try await fixture.runtimeRepository.createJob(jobID: jobID, request: request,
            commandSummary: "owned warm recovery fixture", timeoutSeconds: 5,
            requestArtifactRelativePath: requestRelative)
        if state == .running {
            try await fixture.runtimeRepository.markRunning(jobID: jobID,
                processIdentifier: 424_242, processGroupIdentifier: 424_242,
                processStartIdentity: startIdentity)
        } else if state != .queued {
            throw RuntimeJobError.invalidRequest("warm orphan fixture supports queued or running intent")
        }
        let stored = try await fixture.runtimeRepository.job(jobID)
        return WarmOrphanIntent(record: try XCTUnwrap(stored), outputDirectory: outputDirectory,
            requestDirectory: requestURL.deletingLastPathComponent(), marker: marker)
    }

    func testWarmRuntimeStatusRecoversAbandonedRunningIdentityWithoutReplayingItsRequest() async throws {
        let probe = WarmRecoveredIdentityProbe()
        let fixture = try await Fixture.make(recoveredProcessController: probe)
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        // Fixture.make starts the service while the ledger is empty; this intent
        // appears after that one-time startup recovery has completed.
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 100, microseconds: 7))
        let orphan = try await Self.insertWarmOrphanIntent(fixture: fixture, state: .running,
                                                         startIdentity: start)
        let recovered = try await fixture.service.status(jobID: orphan.record.jobID, context: fixture.context)
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertEqual(recovered.errorCode, "runtime_owner_restarted")
        XCTAssertEqual(recovered.replayClass, .nonReplayable)
        XCTAssertNotNil(recovered.completedAt)
        let events = await probe.observed()
        XCTAssertEqual(events, [.init(signal: SIGTERM, identity: RuntimePersistedProcessIdentity(
            processIdentifier: 424_242, processGroupIdentifier: 424_242, startIdentity: start))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.outputDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.requestDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.marker.path))
        let retainedPath = try await fixture.runtimeRepository.requestArtifactRelativePath(jobID: orphan.record.jobID)
        XCTAssertNil(retainedPath)
    }

    func testWarmRuntimeOutputAndCancellationRecoverQueuedIntentsWithoutReplay() async throws {
        let probe = WarmRecoveredIdentityProbe()
        let fixture = try await Fixture.make(recoveredProcessController: probe)
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let outputIntent = try await Self.insertWarmOrphanIntent(fixture: fixture)
        do {
            _ = try await fixture.service.readOutput(jobID: outputIntent.record.jobID,
                stream: .stdout, offset: 0, limit: 100, context: fixture.context)
            XCTFail("Abandoned partial bytes must not become a successful output page")
        } catch let error as RuntimeJobError {
            if case .outputUnavailable(let jobID, let stream) = error {
                XCTAssertEqual(jobID, outputIntent.record.jobID)
                XCTAssertEqual(stream, .stdout)
            } else {
                XCTFail("Recovered terminal output must be unavailable, not a pending live snapshot: \(error)")
            }
        }
        let outputRow = try await fixture.runtimeRepository.job(outputIntent.record.jobID)
        XCTAssertEqual(outputRow?.state, .failed)
        XCTAssertEqual(outputRow?.errorCode, "runtime_owner_restarted")
        let cancelledIntent = try await Self.insertWarmOrphanIntent(fixture: fixture)
        let cancelledRow = try await fixture.service.cancelAndReturnRecord(
            jobID: cancelledIntent.record.jobID, context: fixture.context)
        // Startup-before-cancel already classifies abandoned queued intent as a
        // failed owner restart. A warm reader must preserve that same contract.
        XCTAssertEqual(cancelledRow.state, .failed)
        XCTAssertEqual(cancelledRow.errorCode, "runtime_owner_restarted")
        for intent in [outputIntent, cancelledIntent] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: intent.outputDirectory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: intent.requestDirectory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: intent.marker.path))
            let retainedPath = try await fixture.runtimeRepository.requestArtifactRelativePath(jobID: intent.record.jobID)
            XCTAssertNil(retainedPath)
        }
        let events = await probe.observed()
        XCTAssertTrue(events.isEmpty, "Queued recovery must not invent a process-start identity")
    }

    func testWarmRuntimeListRequeriesRunningFilterAndPreservesForeignProjectIntent() async throws {
        let probe = WarmRecoveredIdentityProbe()
        let fixture = try await Fixture.make(recoveredProcessController: probe)
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let foreignRoot = fixture.root.appendingPathComponent("warm-foreign-project", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let foreignID = ProjectID()
        _ = try await fixture.controlRepository.registerProjectUnchecked(projectID: foreignID,
            displayName: "Warm foreign intent", canonicalRoot: foreignRoot)
        let foreignOwner = ProjectBindingOwner(kind: .mcpClient, id: "warm-foreign-" + UUID().uuidString)
        _ = try await fixture.controlRepository.bind(owner: foreignOwner, projectID: foreignID,
            generation: .initial, authorizationScope: ToolAuthorizationScope(canonicalRoots: [foreignRoot],
                writableRoots: [foreignRoot], allowedTools: Set(RuntimeJobToolPack.names),
                networkAllowed: false, maximumInlineOutputBytes: fixture.limits.maximumInlineOutputBytes))
        let foreignContext = try await fixture.controlRepository.invocationContext(for: foreignOwner)
        let foreign = try await Self.insertWarmOrphanIntent(fixture: fixture, context: foreignContext)
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 101, microseconds: 8))
        let local = try await Self.insertWarmOrphanIntent(fixture: fixture, state: .running, startIdentity: start)
        do {
            _ = try await fixture.service.status(jobID: foreign.record.jobID, context: fixture.context)
            XCTFail("An ordinary caller must not trigger recovery for another project's job")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_job_scope_mismatch")
        }
        let beforeListEvents = await probe.observed()
        XCTAssertTrue(beforeListEvents.isEmpty)
        let runningRows = try await fixture.service.list(context: fixture.context, states: [.running], limit: 10)
        XCTAssertTrue(runningRows.isEmpty, "A recovered failed row must not leak into the original running filter")
        let allRows = try await fixture.service.list(context: fixture.context, limit: 10)
        XCTAssertEqual(allRows.map(\.jobID), [local.record.jobID])
        XCTAssertEqual(allRows.first?.state, .failed)
        XCTAssertEqual(allRows.first?.errorCode, "runtime_owner_restarted")
        let foreignAfter = try await fixture.runtimeRepository.job(foreign.record.jobID)
        XCTAssertEqual(foreignAfter, foreign.record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.requestDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.marker.path))
        let events = await probe.observed()
        XCTAssertEqual(events, [.init(signal: SIGTERM, identity: RuntimePersistedProcessIdentity(
            processIdentifier: 424_242, processGroupIdentifier: 424_242, startIdentity: start))])
    }

    func testWarmRuntimeRecoveryWithoutExactIdentityFailsClosedAndRetainsIntent() async throws {
        let probe = WarmRecoveredIdentityProbe()
        let fixture = try await Fixture.make(recoveredProcessController: probe)
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let orphan = try await Self.insertWarmOrphanIntent(fixture: fixture, state: .running)
        do {
            _ = try await fixture.service.status(jobID: orphan.record.jobID, context: fixture.context)
            XCTFail("Missing exact identity must block warm recovery instead of claiming cleanup")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }
        let unchanged = try await fixture.runtimeRepository.job(orphan.record.jobID)
        XCTAssertEqual(unchanged, orphan.record)
        XCTAssertNil(unchanged?.completedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.requestDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.marker.path))
        let retainedPath = try await fixture.runtimeRepository.requestArtifactRelativePath(jobID: orphan.record.jobID)
        XCTAssertNotNil(retainedPath)
        let events = await probe.observed()
        XCTAssertTrue(events.isEmpty, "Recovery must never guess a process identity")
    }
}

extension RuntimeExecutionJobTests {
    // Append within the existing RuntimeExecutionJobTests shared-owner extension.
    // Requires its immutable Fixture and warm/shared-owner helpers; no new graph input.

    func testRuntimeOwnershipUnsafeDirectoryAndCoordinatorRefuseBeforeQueuedCommit() async throws {
        for unsafeDirectory in [true, false] {
            let commit = RuntimeBlockingResult<Bool>()
            let fixture = try await Fixture.make(afterMutationCommitObserver: { kind in
                if kind == .submission { commit.store(.success(true)) }
            })
            addTeardownBlock {
                await fixture.close()
                try? FileManager.default.removeItem(at: fixture.root)
            }
            let owners = fixture.root.appendingPathComponent("artifacts/.runtime-owners", isDirectory: true)
            let changed = unsafeDirectory ? owners : owners.appendingPathComponent("coordinator.lock")
            XCTAssertEqual(Darwin.chmod(changed.path, unsafeDirectory ? 0o755 : 0o644), 0)
            let marker = fixture.projectRoot.appendingPathComponent("unsafe-owner-must-not-launch")
            do {
                _ = try await fixture.service.submit(fixture.request(kind: .bash, profile: .bashNoProfile,
                    script: "printf unexpected > " + marker.lastPathComponent, timeout: 5,
                    replayClass: .nonReplayable))
                XCTFail("Unsafe ownership metadata must reject before a queued commit")
            } catch let error as RuntimeJobError {
                XCTAssertEqual(error.code, "runtime_storage_failure")
            }
            XCTAssertNil(commit.take(), "Rejected ownership must not publish a CP submission commit")
            let rows = try await fixture.runtimeRepository.list(context: fixture.context)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testRuntimeOwnershipInventoryAt4096RefusesAndOneRemovalRestoresAdmission() async throws {
        let commit = RuntimeBlockingResult<Bool>()
        let fixture = try await Fixture.make(afterMutationCommitObserver: { kind in
            if kind == .submission { commit.store(.success(true)) }
        })
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let owners = fixture.root.appendingPathComponent("artifacts/.runtime-owners", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owners.path), ["coordinator.lock"])
        let removable = owners.appendingPathComponent(UUID().uuidString.lowercased() + ".lock")
        try Data().write(to: removable)
        XCTAssertEqual(Darwin.chmod(removable.path, 0o600), 0)
        for _ in 0..<4094 {
            let file = owners.appendingPathComponent(UUID().uuidString.lowercased() + ".lock")
            try Data().write(to: file)
            XCTAssertEqual(Darwin.chmod(file.path, 0o600), 0)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owners.path).count, 4096)
        let marker = fixture.projectRoot.appendingPathComponent("restored-owner-capacity")
        let request = fixture.request(kind: .bash, profile: .bashNoProfile,
            script: "printf 'ADMITTED-ONCE\\n' > " + marker.lastPathComponent + "; printf 'capacity-output'",
            timeout: 5, replayClass: .nonReplayable)
        do {
            _ = try await fixture.service.submit(request)
            XCTFail("Exactly 4096 total inventory entries must refuse another owner file")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }
        XCTAssertNil(commit.take())
        let refusedRows = try await fixture.runtimeRepository.list(context: fixture.context)
        XCTAssertTrue(refusedRows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owners.path).count, 4096)
        try FileManager.default.removeItem(at: removable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owners.path).count, 4095)
        let accepted = try await fixture.service.submit(request)
        let terminal = try await fixture.service.waitForTerminal(jobID: accepted, context: fixture.context,
                                                               maximumWait: .seconds(8))
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.exitCode, 0)
        XCTAssertNotNil(commit.take())
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ADMITTED-ONCE\n")
        let rows = try await fixture.runtimeRepository.list(context: fixture.context)
        XCTAssertEqual(rows.map(\.jobID), [accepted])
        let output = try await fixture.service.readOutput(jobID: accepted, stream: .stdout,
            offset: 0, limit: 100, context: fixture.context)
        XCTAssertEqual(output.data, Data("capacity-output".utf8))
        XCTAssertEqual(output.sha256, JSONSupport.sha256Hex(output.data))
        XCTAssertFalse(output.isSnapshot)
        XCTAssertEqual(output.producerEndReason, .eof)
        XCTAssertNil(output.producerReadErrno)
        XCTAssertFalse(output.artifactTruncated)
    }

    func testRuntimeStartupSymlinkOwnerLockFailsClosedWithoutTouchingIntentOrSignaling() async throws {
        let fixture = try await Fixture.make()
        let observer = try await SharedOwnerObserver.make(fixture: fixture)
        let probe = WarmRecoveredIdentityProbe()
        try await observer.service.setRecoveredProcessController(probe)
        addTeardownBlock {
            await observer.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 102, microseconds: 9))
        let orphan = try await Self.insertWarmOrphanIntent(fixture: fixture, state: .running,
                                                         startIdentity: start)
        let target = fixture.root.appendingPathComponent("owned-harmless-lock-target")
        try Data().write(to: target)
        XCTAssertEqual(Darwin.chmod(target.path, 0o600), 0)
        let ownerFile = fixture.root.appendingPathComponent("artifacts/.runtime-owners/"
            + orphan.record.jobID.uuidString.lowercased() + ".lock")
        try FileManager.default.createSymbolicLink(atPath: ownerFile.path, withDestinationPath: target.path)
        do {
            try await observer.service.start()
            XCTFail("A symlink owner file is not an admissible recovery lease")
        } catch let error as RuntimeJobError {
            XCTAssertEqual(error.code, "runtime_storage_failure")
        }
        let unchanged = try await fixture.runtimeRepository.job(orphan.record.jobID)
        XCTAssertEqual(unchanged, orphan.record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.requestDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.marker.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: ownerFile.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        let events = await probe.observed()
        XCTAssertTrue(events.isEmpty)
        let shutdown = await observer.service.shutdown()
        XCTAssertFalse(shutdown.completed)
        XCTAssertTrue(shutdown.unresolvedJobIDs.contains(orphan.record.jobID))
    }

    private actor CancelledWarmIdentityProbe: RuntimeRecoveredProcessControlling {
        let gate: SharedOwnerPreparationGate
        let gateTag: UUID
        private var count = 0
        private var identity: RuntimePersistedProcessIdentity?
        private var differentIdentity = false

        init(gate: SharedOwnerPreparationGate, gateTag: UUID) {
            self.gate = gate
            self.gateTag = gateTag
        }

        func signalProcessGroup(_ signal: Int32, expectedIdentity: RuntimePersistedProcessIdentity)
            async -> RuntimeRecoveredProcessSignalResult {
            count = min(4096, count + 1)
            if let identity, identity != expectedIdentity { differentIdentity = true }
            identity = expectedIdentity
            if count == 1 { try? await gate.pause(jobID: gateTag) }
            return .identityUnavailable
        }

        func observed() -> (count: Int, identity: RuntimePersistedProcessIdentity?, differentIdentity: Bool) {
            (count, identity, differentIdentity)
        }
    }

    func testCancelledWarmRecoveryRetainsProbeCadenceAndReleasesLeaseWithHonestDebt() async throws {
        let gate = SharedOwnerPreparationGate()
        let tag = UUID()
        let probe = CancelledWarmIdentityProbe(gate: gate, gateTag: tag)
        let limits = RuntimeJobLimits(maximumConcurrentJobs: 1, maximumCPUHeavyJobs: 1,
            maximumQueuedJobs: 2, maximumInlineOutputBytes: 256, maximumArtifactBytesPerJob: 4096,
            maximumScriptBytes: 8192, maximumArguments: 32, maximumArgumentBytes: 4096,
            maximumTimeoutSeconds: 30, terminationGraceMilliseconds: 60,
            forcedTerminationGraceMilliseconds: 60)
        let fixture = try await Fixture.make(limits: limits, recoveredProcessController: probe)
        let observer = try await SharedOwnerObserver.make(fixture: fixture)
        let cleanupProbe = WarmRecoveredIdentityProbe()
        try await observer.service.setRecoveredProcessController(cleanupProbe)
        let start = try XCTUnwrap(RuntimeProcessStartIdentity(seconds: 103, microseconds: 10))
        let orphan = try await Self.insertWarmOrphanIntent(fixture: fixture, state: .running,
                                                         startIdentity: start)
        let operation = Task { try await fixture.service.status(jobID: orphan.record.jobID, context: fixture.context) }
        addTeardownBlock {
            operation.cancel()
            await gate.release()
            _ = await operation.result
            await observer.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let entered = await Self.waitUntil { await gate.observedJobID() == tag }
        XCTAssertTrue(entered)
        let owners = fixture.root.appendingPathComponent("artifacts/.runtime-owners", isDirectory: true)
        // Keep one reader of the original inode, even if normal cleanup unlinks
        // its pathname. A replacement owner file cannot satisfy this lock proof.
        let ownerURL = owners.appendingPathComponent(orphan.record.jobID.uuidString.lowercased() + ".lock")
        let reader = Darwin.open(ownerURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard reader >= 0 else { throw RuntimeJobError.storageFailure("cadence owner reader is unavailable") }
        defer { _ = flock(reader, LOCK_UN); _ = Darwin.close(reader) }
        var before = stat()
        XCTAssertEqual(Darwin.fstat(reader, &before), 0)
        XCTAssertEqual(before.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(before.st_mode & 0o777, 0o600)
        XCTAssertEqual(before.st_size, 0)
        XCTAssertEqual(before.st_uid, geteuid())
        let initialLock = flock(reader, LOCK_EX | LOCK_NB)
        let initialError = errno
        XCTAssertEqual(initialLock, -1, "The original owner must hold this inode while its probe is paused")
        XCTAssertTrue(initialError == EWOULDBLOCK || initialError == EAGAIN)
        operation.cancel()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("The cancelled caller must not receive an ordinary successful status")
        } catch is CancellationError {}
        let evidence = await probe.observed()
        XCTAssertGreaterThanOrEqual(evidence.count, 1)
        XCTAssertLessThanOrEqual(evidence.count, 12,
            "A cancelled sleep must not turn the 20ms recovery cadence into continuous probes")
        XCTAssertFalse(evidence.differentIdentity)
        let expected = RuntimePersistedProcessIdentity(processIdentifier: 424_242,
            processGroupIdentifier: 424_242, startIdentity: start)
        XCTAssertEqual(evidence.identity, expected)
        let debt = try await fixture.runtimeRepository.job(orphan.record.jobID)
        XCTAssertEqual(debt?.state, .failed)
        XCTAssertEqual(debt?.errorCode, "runtime_termination_unconfirmed")
        XCTAssertTrue(debt?.errorSummary?.contains("cleanup_debt_resolved=false") == true)
        XCTAssertTrue(debt?.errorSummary?.contains("restart_attempts=1;") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.marker.path))
        var after = stat()
        XCTAssertEqual(Darwin.fstat(reader, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(flock(reader, LOCK_EX | LOCK_NB), 0,
            "Another reader must acquire the released original owner inode")
        XCTAssertEqual(flock(reader, LOCK_UN), 0)
        // Startup-style cleanup already consumed its one restart retry. A later
        // reader must preserve honest terminal debt instead of signaling again.
        try await observer.service.start()
        let cleanupEvents = await cleanupProbe.observed()
        XCTAssertTrue(cleanupEvents.isEmpty)
        let afterReader = try await fixture.runtimeRepository.job(orphan.record.jobID)
        XCTAssertEqual(afterReader, debt)
    }
}

extension RuntimeExecutionJobTests {
    func testSubsystemShutdownPreservesSuccessfulReportAfterRepositoryClose() async throws {
        let fixture = try await Fixture.make()
        let subsystem = try RuntimeJobSubsystem(
            controlPlaneRepository: fixture.controlRepository,
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite"),
            artifactRoot: fixture.root.appendingPathComponent("subsystem-artifacts", isDirectory: true),
            limits: fixture.limits
        )
        addTeardownBlock {
            _ = await subsystem.shutdown()
            await subsystem.repository.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let first = await subsystem.shutdown()
        XCTAssertTrue(first.completed)
        XCTAssertTrue(first.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(first.persistencePendingJobIDs.isEmpty)
        do {
            _ = try await subsystem.repository.health()
            XCTFail("Completed subsystem shutdown must close its repository")
        } catch {
            XCTAssertEqual(error as? RuntimeJobError, .repositoryClosed)
        }

        let second = await subsystem.shutdown()
        XCTAssertEqual(second, first, "The same subsystem must retain its successful shutdown report after closing storage")
    }

    func testSubsystemShutdownCannotCertifyPlainRepositoryClose() async throws {
        let fixture = try await Fixture.make()
        let subsystem = try RuntimeJobSubsystem(
            controlPlaneRepository: fixture.controlRepository,
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite"),
            artifactRoot: fixture.root.appendingPathComponent("subsystem-artifacts", isDirectory: true),
            limits: fixture.limits
        )
        addTeardownBlock {
            _ = await subsystem.shutdown()
            await subsystem.repository.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await subsystem.repository.close()

        let first = await subsystem.shutdown()
        XCTAssertFalse(first.completed, "Plain close is not a successful shutdown certification")
        XCTAssertTrue(first.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(first.persistencePendingJobIDs.isEmpty)
        let second = await subsystem.shutdown()
        XCTAssertEqual(second, first)
    }

    func testConcurrentSubsystemShutdownPreservesSuccessfulReportsAfterClose() async throws {
        let fixture = try await Fixture.make()
        let subsystem = try RuntimeJobSubsystem(
            controlPlaneRepository: fixture.controlRepository,
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite"),
            artifactRoot: fixture.root.appendingPathComponent("subsystem-artifacts", isDirectory: true),
            limits: fixture.limits
        )
        addTeardownBlock {
            _ = await subsystem.shutdown()
            await subsystem.repository.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        // Two structured calls exercise an idle, unstarted actual subsystem.
        // This is bounded concurrency parity, not a forced scheduler interleaving.
        async let first = subsystem.shutdown()
        async let second = subsystem.shutdown()
        let reports = await (first, second)
        XCTAssertTrue(reports.0.completed)
        XCTAssertTrue(reports.1.completed)
        XCTAssertEqual(reports.0, reports.1)
        XCTAssertTrue(reports.0.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(reports.0.persistencePendingJobIDs.isEmpty)
        let repeated = await subsystem.shutdown()
        XCTAssertEqual(repeated, reports.0)
    }

    func testDirectServiceShutdownStillInspectsClosedRepositoryAfterPriorSuccess() async throws {
        let fixture = try await Fixture.make()
        addTeardownBlock {
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let first = await fixture.service.shutdown()
        XCTAssertTrue(first.completed)
        await fixture.runtimeRepository.close()

        let second = await fixture.service.shutdown()
        XCTAssertFalse(second.completed, "Direct service shutdown must still inspect its closed durable ledger")
        XCTAssertTrue(second.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(second.persistencePendingJobIDs.isEmpty)
    }
}

extension RuntimeExecutionJobTests {
    func testSubsystemShutdownReconciliationPreservesFailureUntilActualCertification() async throws {
        let fixture = try await Fixture.make()
        let subsystem = try RuntimeJobSubsystem(
            controlPlaneRepository: fixture.controlRepository,
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite"),
            artifactRoot: fixture.root.appendingPathComponent("subsystem-artifacts", isDirectory: true),
            limits: fixture.limits
        )
        addTeardownBlock {
            _ = await subsystem.shutdown()
            await subsystem.repository.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        // Only the incoming failed report is a fixture value. Successful
        // certification must come from the real subsystem shutdown below.
        let failed = RuntimeJobShutdownReport(
            completed: false,
            unresolvedJobIDs: [UUID()],
            persistencePendingJobIDs: [UUID()]
        )
        let beforeCertification = await subsystem.repository.completeSubsystemShutdown(failed)
        XCTAssertEqual(beforeCertification, failed)
        let uncertified = await subsystem.repository.subsystemShutdownReport()
        XCTAssertNil(uncertified)
        let readable = try await subsystem.repository.health()
        XCTAssertEqual(readable.integrity, "ok", "An incomplete report must not close readable storage")

        let first = await subsystem.shutdown()
        XCTAssertTrue(first.completed)
        XCTAssertTrue(first.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(first.persistencePendingJobIDs.isEmpty)
        let certification = await subsystem.repository.subsystemShutdownReport()
        XCTAssertEqual(certification, Optional(first))
        let afterCertification = await subsystem.repository.completeSubsystemShutdown(failed)
        XCTAssertEqual(afterCertification, first, "Reconciliation must return the actual prior successful report")
        do {
            _ = try await subsystem.repository.health()
            XCTFail("Certified subsystem shutdown must leave storage closed")
        } catch {
            XCTAssertEqual(error as? RuntimeJobError, .repositoryClosed)
        }
    }

    func testStartedSubsystemShutdownPreservesSuccessfulReportAfterRepositoryClose() async throws {
        let fixture = try await Fixture.make()
        let subsystem = try RuntimeJobSubsystem(
            controlPlaneRepository: fixture.controlRepository,
            databaseURL: fixture.root.appendingPathComponent("control-plane.sqlite"),
            artifactRoot: fixture.root.appendingPathComponent("subsystem-artifacts", isDirectory: true),
            limits: fixture.limits
        )
        addTeardownBlock {
            _ = await subsystem.shutdown()
            await subsystem.repository.close()
            await fixture.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await subsystem.start()

        let first = await subsystem.shutdown()
        XCTAssertTrue(first.completed)
        XCTAssertTrue(first.unresolvedJobIDs.isEmpty)
        XCTAssertTrue(first.persistencePendingJobIDs.isEmpty)
        do {
            _ = try await subsystem.repository.health()
            XCTFail("Completed started-subsystem shutdown must close its repository")
        } catch {
            XCTAssertEqual(error as? RuntimeJobError, .repositoryClosed)
        }
        let second = await subsystem.shutdown()
        XCTAssertEqual(second, first)
    }
}

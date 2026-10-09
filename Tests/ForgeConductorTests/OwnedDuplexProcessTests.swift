// Exercises native pipe bytes and prelaunch owned-mode rejection without a child fixture.

import Darwin
import Foundation
import XCTest
@testable import ForgeConductorCore

final class OwnedDuplexProcessTests: XCTestCase {
    func testDOCXFixedModeCapsPreserveWebTransportAndRejectOversizeBeforeAdmission() throws {
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV1.argument, "--internal-web-render-v1")
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV1.maximumInputBytes, 16_388)
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV1.maximumOutputBytes, 32_772)
        XCTAssertEqual(OwnedCurrentSelfMode.docxExportV1.argument, "--internal-docx-export-v1")
        XCTAssertEqual(OwnedCurrentSelfMode.docxExportV1.maximumInputBytes, 65_536)
        XCTAssertEqual(OwnedCurrentSelfMode.docxExportV1.maximumOutputBytes, 1_048_576)
        let runner = ProcessRunner()
        let result = try runOnWorker {
            try runner.runOwnedCurrentSelf(mode: .docxExportV1,
                standardInput: Data(repeating: 0, count: 65_537),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
                cancellation: ToolCallCancellation())
        }
        switch result {
        case .failure(let error):
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ProcessRunner")
            XCTAssertEqual(failure.code, 21)
        case .success: XCTFail("Oversize DOCX input must fail before native admission")
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testCompleteRendererFixedModeCapsRejectOversizeBeforeAdmission() throws {
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV2.argument, "--internal-web-render-v2")
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV2.maximumInputBytes, 16_388)
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV2.maximumOutputBytes, 6_347_780)
        XCTAssertEqual(OwnedCurrentSelfMode.webRenderV1.maximumOutputBytes, 32_772)
        let runner = ProcessRunner()
        let result = try runOnWorker {
            try runner.runOwnedCurrentSelf(mode: .webRenderV2,
                standardInput: Data(repeating: 0, count: 16_389),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
                cancellation: ToolCallCancellation())
        }
        switch result {
        case .failure(let error):
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ProcessRunner")
            XCTAssertEqual(failure.code, 21)
        case .success: XCTFail("Oversize v2 input must fail before native admission")
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testOpenEmptyPipeIsNotEOFAndFinalizationReportsForcedClose() throws {
        let pipe = try OwnedCaptureTestPipe()
        let capture = OwnedPipeCapture(limit: 32)

        XCTAssertFalse(capture.drain(pipe.readDescriptor))
        XCTAssertNil(capture.end)
        let unfinished = capture.finish()
        XCTAssertEqual(unfinished.end, .forcedClose)
        XCTAssertTrue(unfinished.data.isEmpty)
        XCTAssertFalse(unfinished.truncated)

        try pipe.closeWriter()
        try drainUntilTerminal(capture, descriptor: pipe.readDescriptor)
        XCTAssertEqual(capture.finish().end, .eof)
        XCTAssertFalse(capture.finish().truncated)
    }

    func testExactCapAndMalformedUTF8RemainExactBytesAtEOF() throws {
        let pipe = try OwnedCaptureTestPipe()
        // Includes NUL, invalid UTF-8, and an incomplete UTF-8 suffix.
        let payload = Data([0x00, 0xff, 0x80, 0xe2, 0x82])
        let capture = OwnedPipeCapture(limit: payload.count)
        var sent = 0
        try pump(payload, offset: &sent, pipe: pipe, capture: capture)

        XCTAssertEqual(sent, payload.count)
        let result = capture.finish()
        XCTAssertEqual(result.data, payload)
        XCTAssertEqual(result.end, .eof)
        XCTAssertFalse(result.truncated)
        // Terminal evidence is sticky; another drain must not overwrite EOF.
        XCTAssertFalse(capture.drain(-1))
        XCTAssertEqual(capture.finish().end, .eof)
        XCTAssertEqual(capture.finish().data, payload)
    }

    func testRetentionOverflowStillDiscardsThroughActualEOF() throws {
        let pipe = try OwnedCaptureTestPipe()
        let payload = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        let capture = OwnedPipeCapture(limit: 17)
        var sent = 0
        try pump(payload, offset: &sent, pipe: pipe, capture: capture)

        XCTAssertEqual(sent, payload.count)
        let result = capture.finish()
        XCTAssertEqual(result.data, Data(payload.prefix(17)))
        XCTAssertEqual(result.end, .eof)
        XCTAssertTrue(result.truncated)
    }

    func testZeroRetentionCapStillDrainsNonemptyPipeToEOF() throws {
        let pipe = try OwnedCaptureTestPipe()
        let payload = Data([0x00, 0x7f, 0xff])
        let capture = OwnedPipeCapture(limit: 0)
        var sent = 0
        try pump(payload, offset: &sent, pipe: pipe, capture: capture)

        let result = capture.finish()
        XCTAssertEqual(sent, payload.count)
        XCTAssertTrue(result.data.isEmpty)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.end, .eof)
    }

    func testReadErrorIsDistinctFromEOFAndForcedClose() {
        let capture = OwnedPipeCapture(limit: 32)
        XCTAssertFalse(capture.drain(-1))
        XCTAssertEqual(capture.end, .readError(EBADF))
        let result = capture.finish()
        XCTAssertEqual(result.end, .readError(EBADF))
        XCTAssertTrue(result.data.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(capture.drain(-1))
        XCTAssertEqual(capture.finish().end, .readError(EBADF))
    }

    func testTwoCappedPipeStreamsDrainIndependentlyToEOF() throws {
        let stdoutPipe = try OwnedCaptureTestPipe()
        let stderrPipe = try OwnedCaptureTestPipe()
        let stdout = OwnedPipeCapture(limit: 64)
        let stderr = OwnedPipeCapture(limit: 256)
        let stdoutPayload = Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0) })
        var stderrPayload = Data("stderr marker survives stdout overflow\n".utf8)
        stderrPayload.append(Data(repeating: 0xa5, count: 196_608))
        var stdoutSent = 0
        var stderrSent = 0

        // All descriptors are nonblocking. Alternate finite writes and both drains;
        // no assumption about the platform's pipe capacity or a writer thread.
        for _ in 0..<512 {
            try stdoutPipe.writeSome(stdoutPayload, offset: &stdoutSent)
            try stderrPipe.writeSome(stderrPayload, offset: &stderrSent)
            if stdoutSent == stdoutPayload.count { try stdoutPipe.closeWriter() }
            if stderrSent == stderrPayload.count { try stderrPipe.closeWriter() }
            stdout.drain(stdoutPipe.readDescriptor)
            stderr.drain(stderrPipe.readDescriptor)
            if stdout.end != nil, stderr.end != nil { break }
        }

        XCTAssertEqual(stdoutSent, stdoutPayload.count)
        XCTAssertEqual(stderrSent, stderrPayload.count)
        XCTAssertEqual(stdout.finish().end, .eof)
        XCTAssertEqual(stderr.finish().end, .eof)
        XCTAssertEqual(stdout.finish().data, Data(stdoutPayload.prefix(64)))
        XCTAssertEqual(stderr.finish().data, Data(stderrPayload.prefix(256)))
        XCTAssertTrue(stdout.finish().truncated)
        XCTAssertTrue(stderr.finish().truncated)
    }

    @MainActor
    func testOwnedModeRejectsMainThreadBeforeAdmission() async throws {
        guard Self.mainThreadFixture() else {
            XCTFail("main-actor fixture did not execute on the main thread")
            return
        }
        let runner = ProcessRunner()
        XCTAssertThrowsError(try runner.runOwnedCurrentSelf(
            mode: .webRenderV1,
            standardInput: Data(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
            cancellation: ToolCallCancellation()
        )) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ProcessRunner")
            XCTAssertEqual(failure.code, 20)
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testOversizedOwnedInputIsRejectedOnWorkerBeforeAdmission() throws {
        let runner = ProcessRunner()
        let result = try runOnWorker {
            try runner.runOwnedCurrentSelf(
                mode: .webRenderV1,
                standardInput: Data(repeating: 0, count: 16_389),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
                cancellation: ToolCallCancellation()
            )
        }
        switch result {
        case .failure(let error):
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ProcessRunner")
            XCTAssertEqual(failure.code, 21)
        case .success:
            XCTFail("oversized input must fail before native admission")
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testExpiredOwnedDeadlineReleasesReservationWithoutChild() throws {
        let runner = ProcessRunner()
        for _ in 0..<2 {
            let result = try runOnWorker {
                try runner.runOwnedCurrentSelf(
                    mode: .webRenderV1,
                    standardInput: Data([0]),
                    deadlineUptimeNanoseconds: 0,
                    cancellation: ToolCallCancellation()
                )
            }
            switch result {
            case .failure(let error):
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
            case .success:
                XCTFail("an expired deadline must fail before native admission")
            }
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testPrecancelledOwnedCallDoesNotCreateRecoveryWork() throws {
        let runner = ProcessRunner()
        let cancellation = ToolCallCancellation()
        cancellation.cancel()
        let result = try runOnWorker {
            try runner.runOwnedCurrentSelf(
                mode: .webRenderV1,
                standardInput: Data([0]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000,
                cancellation: cancellation
            )
        }
        switch result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        case .success:
            XCTFail("a precancelled call must fail before native admission")
        }
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    func testRecoveryWithoutOwnedChildSucceedsEvenAfterDeadline() {
        let runner = ProcessRunner()
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
        XCTAssertTrue(runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: 0))
    }

    private static func mainThreadFixture() -> Bool { Thread.isMainThread }

    private func pump(_ payload: Data, offset: inout Int, pipe: OwnedCaptureTestPipe,
                      capture: OwnedPipeCapture) throws {
        for _ in 0..<512 {
            try pipe.writeSome(payload, offset: &offset)
            if offset == payload.count { try pipe.closeWriter() }
            capture.drain(pipe.readDescriptor)
            if capture.end != nil { break }
        }
        XCTAssertEqual(offset, payload.count, "finite pipe payload did not finish writing")
        XCTAssertEqual(capture.end, .eof, "finite pipe payload did not reach actual EOF")
    }

    private func drainUntilTerminal(_ capture: OwnedPipeCapture, descriptor: Int32) throws {
        for _ in 0..<32 {
            capture.drain(descriptor)
            if capture.end != nil { return }
        }
        throw OwnedCaptureTestError.captureDidNotFinish
    }

    private func runOnWorker(
        _ operation: @escaping @Sendable () throws -> OwnedDuplexResult
    ) throws -> Result<OwnedDuplexResult, Error> {
        let result = OwnedCaptureTestResult()
        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.leave() }
            result.store(Result { try operation() })
        }
        guard completed.wait(timeout: .now() + 2) == .success else {
            throw OwnedCaptureTestError.workerDidNotFinish
        }
        return try XCTUnwrap(result.value)
    }
}

private enum OwnedCaptureTestError: Error {
    case captureDidNotFinish
    case workerDidNotFinish
}

private final class OwnedCaptureTestPipe {
    private let pipe = Pipe()
    private var writerClosed = false

    var readDescriptor: Int32 { pipe.fileHandleForReading.fileDescriptor }

    init() throws {
        for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0 else { throw Self.posixFailure(errno) }
            guard fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Self.posixFailure(errno)
            }
        }
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Self.posixFailure(errno)
        }
    }

    func writeSome(_ payload: Data, offset: inout Int) throws {
        guard !writerClosed, offset < payload.count else { return }
        let count = payload.withUnsafeBytes { bytes in
            Darwin.write(pipe.fileHandleForWriting.fileDescriptor,
                         bytes.baseAddress!.advanced(by: offset), min(4_096, payload.count - offset))
        }
        if count > 0 { offset += count; return }
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
        throw Self.posixFailure(count == 0 ? EIO : errno)
    }

    func closeWriter() throws {
        guard !writerClosed else { return }
        try pipe.fileHandleForWriting.close()
        writerClosed = true
    }

    deinit {
        try? pipe.fileHandleForReading.close()
        if !writerClosed { try? pipe.fileHandleForWriting.close() }
    }

    private static func posixFailure(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private final class OwnedCaptureTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<OwnedDuplexResult, Error>?

    var value: Result<OwnedDuplexResult, Error>? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func store(_ value: Result<OwnedDuplexResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        storage = value
    }
}

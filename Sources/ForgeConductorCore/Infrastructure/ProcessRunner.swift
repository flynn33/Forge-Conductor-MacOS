// ProcessRunner.swift
// What: Provides the bounded native subprocess adapter used by connector modules.
// How: posix_spawn creates an owned process group with explicit environment, working
// directory, timeout, cancellation, and capped stdout/stderr collection behavior.
// Why: Every module must share the same resource and failure semantics for child processes.

import Foundation
import Darwin

/// Describes a completed subprocess, including timeout and output-cap evidence.
///
/// Truncation flags let callers distinguish complete diagnostics from output that was
/// intentionally bounded to protect the long-running host process.
public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var terminationSignal: Int32? = nil
}

enum OwnedCurrentSelfMode: Sendable {
    case webRenderV1
    case webRenderV2
    case docxExportV1
    case aacM4AV1

    var argument: String {
        switch self {
        case .webRenderV1: "--internal-web-render-v1"
        case .webRenderV2: "--internal-web-render-v2"
        case .docxExportV1: "--internal-docx-export-v1"
        case .aacM4AV1: "--internal-aac-m4a-v1"
        }
    }

    var maximumInputBytes: Int {
        switch self {
        case .webRenderV1: 16_388
        case .webRenderV2: WebRenderProtocol.maximumRequestBodyBytes + 4
        case .docxExportV1: 65_536
        case .aacM4AV1: AACM4AProtocol.maximumRequestBytes
        }
    }

    var maximumOutputBytes: Int {
        switch self {
        case .webRenderV1: 32_772
        case .webRenderV2: WebRenderProtocol.Profile.completeV2.maximumReplyBodyBytes + 4
        case .docxExportV1: 1_048_576
        case .aacM4AV1: AACM4AProtocol.maximumReplyBytes
        }
    }
}

enum OwnedStreamEnd: Sendable, Equatable {
    case eof
    case readError(Int32)
    case forcedClose
}

struct OwnedCapturedStream: Sendable {
    let data: Data
    let end: OwnedStreamEnd
    let truncated: Bool
}

enum OwnedAdmissionDisposition: Sendable {
    case notAttempted
    case admitted
    case roleRejected
    case auditTokenUnavailable
    case childInvalid
    case exactIdentityMismatch
    case ownedChildExited
}

struct OwnedDuplexResult: Sendable {
    let exitCode: Int32?
    let terminationSignal: Int32?
    let stdout: OwnedCapturedStream
    let stderr: OwnedCapturedStream
    let stdinBytesWritten: Int
    let stdinClosed: Bool
    let admission: OwnedAdmissionDisposition
    let timedOut: Bool
    let cancelled: Bool
    let termRequested: Bool
    let killRequested: Bool
    let terminationConfirmed: Bool
}

struct OwnedNativeTerminationUnconfirmed: Error, Sendable, LocalizedError {
    let processIdentifier: Int32
    let signalError: Int32?
    let waitError: Int32?
    let killRequested: Bool

    var errorDescription: String? {
        "owned native child \(processIdentifier) termination was not confirmed"
    }
}

/// One waitpid owner. Signal and reap share this lock so a watchdog cannot
/// signal a PID after this owner has reaped it. Security calls hold no lock.
private final class OwnedNativeChild: @unchecked Sendable {
    struct Status {
        var exitCode: Int32?
        var signal: Int32?
        var waitError: Int32?
        var termAt: UInt64?
        var killRequested = false
        var signalError: Int32?
        var timedOut = false
        var cancelled = false
    }
    let pid: Int32
    private let lock = NSLock()
    private var status = Status()

    init(pid: Int32) {
        self.pid = pid
        RuntimeDiagnostics.shared.increment(.processLaunches)
        RuntimeDiagnostics.shared.adjust(.childProcesses, by: 1)
    }

    func snapshot() -> Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    @discardableResult
    func pollTerminal() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if status.exitCode != nil { return true }
        // A failed wait cannot grant permission to signal a potentially reused PID.
        if status.waitError != nil { return false }
        var raw: Int32 = 0
        let result = Darwin.waitpid(pid, &raw, WNOHANG)
        if result == pid {
            let signal = raw & 0x7f
            status.signal = signal == 0 ? nil : signal
            status.exitCode = signal == 0 ? (raw >> 8) & 0xff : signal
            RuntimeDiagnostics.shared.adjust(.childProcesses, by: -1)
            RuntimeDiagnostics.shared.increment(.processExits)
            return true
        }
        if result < 0, errno != EINTR { status.waitError = errno }
        return false
    }

    func requestTermination(now: UInt64, timedOut: Bool, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard status.exitCode == nil, status.waitError == nil else { return }
        status.timedOut = status.timedOut || timedOut
        status.cancelled = status.cancelled || cancelled
        guard !status.killRequested else { return }
        if status.termAt == nil {
            status.termAt = now
            signalLocked(SIGTERM)
        } else if now - status.termAt! >= 500_000_000, !status.killRequested {
            status.killRequested = true
            signalLocked(SIGKILL)
        }
    }

    func forceTerminationAtDeadline(cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard status.exitCode == nil, status.waitError == nil, !status.killRequested else { return }
        status.timedOut = true
        status.cancelled = status.cancelled || cancelled
        status.killRequested = true
        signalLocked(SIGKILL)
    }

    func writeAdmitted(_ descriptor: Int32, data: Data, offset: Int,
                       cancellation: ToolCallCancellation, stopWorkAt: UInt64) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard status.exitCode == nil, status.waitError == nil, status.termAt == nil, !status.killRequested,
              !cancellation.isCancelled, !cancellation.isDeadlineExceeded,
              DispatchTime.now().uptimeNanoseconds < stopWorkAt else { return nil }
        // This descriptor is nonblocking; holding the ownership lock for this
        // single finite write prevents the watchdog starting cleanup mid-write.
        return data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset),
                         min(4_096, bytes.count - offset))
        }
    }

    private func signalLocked(_ signal: Int32) {
        if Darwin.kill(-pid, signal) != 0, errno != ESRCH { status.signalError = errno }
        if Darwin.kill(pid, signal) != 0, errno != ESRCH, status.signalError == nil {
            status.signalError = errno
        }
    }
}

final class OwnedPipeCapture {
    private(set) var data = Data()
    private(set) var end: OwnedStreamEnd?
    private(set) var truncated = false
    private let limit: Int
    private var buffer = [UInt8](repeating: 0, count: 8_192)

    init(limit: Int) { self.limit = limit }

    @discardableResult
    func drain(_ descriptor: Int32) -> Bool {
        guard end == nil else { return false }
        var consumed = false
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                consumed = true
                let retained = min(count, max(0, limit - data.count))
                data.append(contentsOf: buffer.prefix(retained))
                truncated = truncated || retained < count
            } else if count == 0 {
                end = .eof
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                end = .readError(errno)
                break
            }
        }
        return consumed
    }

    func finish() -> OwnedCapturedStream {
        OwnedCapturedStream(data: data, end: end ?? .forcedClose, truncated: truncated)
    }
}

private final class OwnedNativeWatchdog: @unchecked Sendable {
    private let source: DispatchSourceTimer

    init(child: OwnedNativeChild, cancellation: ToolCallCancellation, stopWorkAt: UInt64, end: UInt64) {
        source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(25))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let cancelled = cancellation.isCancelled
            let timedOut = now >= stopWorkAt || cancellation.isDeadlineExceeded
            if now >= end {
                child.forceTerminationAtDeadline(cancelled: cancelled)
                self.source.cancel()
                return
            }
            if cancelled || timedOut {
                child.requestTermination(now: now, timedOut: timedOut, cancelled: cancelled)
            }
        }
        source.resume()
    }

    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

extension ProcessRunner {
    /// Internal fixed native mode: no caller-selected executable, arguments,
    /// environment, or admission predicate. Payload starts only after admission.
    func runOwnedCurrentSelf(
        mode: OwnedCurrentSelfMode,
        standardInput: Data,
        deadlineUptimeNanoseconds suppliedDeadline: UInt64,
        cancellation: ToolCallCancellation
    ) throws -> OwnedDuplexResult {
        guard !Thread.isMainThread else {
            throw NSError(domain: "ProcessRunner", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "owned native mode requires a worker thread"])
        }
        guard standardInput.count <= mode.maximumInputBytes else {
            throw NSError(domain: "ProcessRunner", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "owned native input exceeds its frame limit"])
        }
        try cancellation.checkCancellation()
        ownedModeLock.lock()
        guard !ownedModeReserved, ownedModeChild == nil else {
            ownedModeLock.unlock()
            throw NSError(domain: "ProcessRunner", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "owned native mode is busy or unresolved"])
        }
        ownedModeReserved = true
        ownedModeLock.unlock()
        defer {
            ownedModeLock.lock()
            ownedModeReserved = false
            if ownedModeChild?.snapshot().exitCode != nil { ownedModeChild = nil }
            ownedModeLock.unlock()
        }

        let entered = DispatchTime.now().uptimeNanoseconds
        var end = min(suppliedDeadline, entered + 30_000_000_000)
        if let remaining = cancellation.remainingTimeInterval {
            end = min(end, entered + UInt64(max(0, min(30, remaining)) * 1_000_000_000))
        }
        guard end > entered, end - entered > 2_500_000_000 else {
            throw ToolCallDeadlineExceeded()
        }
        let stopWorkAt = end - 1_500_000_000
        let identity = try OwnedCurrentSelfAdmission.current()
        try cancellation.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < stopWorkAt else {
            throw ToolCallDeadlineExceeded()
        }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        let inputRead = input.fileHandleForReading, inputWrite = input.fileHandleForWriting
        let outputRead = output.fileHandleForReading, outputWrite = output.fileHandleForWriting
        let errorRead = errors.fileHandleForReading, errorWrite = errors.fileHandleForWriting
        let handles = [inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite]
        defer { for handle in handles { try? handle.close() } }
        for handle in [inputWrite, outputRead, errorRead] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Self.posixError(errno, operation: "configure owned nonblocking pipe")
            }
        }
        guard fcntl(inputWrite.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Self.posixError(errno, operation: "suppress owned pipe SIGPIPE")
        }
        try cancellation.checkCancellation()
        let beforeSpawn = DispatchTime.now().uptimeNanoseconds
        guard end > beforeSpawn, end - beforeSpawn > 2_500_000_000 else {
            throw ToolCallDeadlineExceeded()
        }
        let pid = try Self.spawn(executable: identity.executable, arguments: [mode.argument],
            currentDirectory: nil, environment: [:], inheritEnvironment: false,
            stdoutDescriptors: [outputRead.fileDescriptor, outputWrite.fileDescriptor],
            stderrDescriptors: [errorRead.fileDescriptor, errorWrite.fileDescriptor],
            stdinDescriptors: [inputRead.fileDescriptor, inputWrite.fileDescriptor])
        let child = OwnedNativeChild(pid: pid)
        RuntimeDiagnostics.shared.adjust(.processReaders, by: 2)
        defer { RuntimeDiagnostics.shared.adjust(.processReaders, by: -2) }
        ownedModeLock.lock(); ownedModeChild = child; ownedModeLock.unlock()
        try? inputRead.close(); try? outputWrite.close(); try? errorWrite.close()
        let watchdog = OwnedNativeWatchdog(child: child, cancellation: cancellation,
                                           stopWorkAt: stopWorkAt, end: end)
        defer { watchdog.cancel() }

        var admission: OwnedAdmissionDisposition = .notAttempted
        if !child.pollTerminal() {
            do {
                try OwnedCurrentSelfAdmission.validateOwnedChild(pid: pid, matching: identity)
                if child.pollTerminal() { admission = .ownedChildExited }
                else { admission = .admitted }
            } catch let error as OwnedCurrentSelfAdmissionError {
                switch error {
                case .roleRejected, .roleMismatch: admission = .roleRejected
                case .auditTokenUnavailable, .auditTokenMismatch: admission = .auditTokenUnavailable
                case .exactIdentityMismatch: admission = .exactIdentityMismatch
                default: admission = .childInvalid
                }
            } catch { admission = .childInvalid }
        } else { admission = .ownedChildExited }

        let out = OwnedPipeCapture(limit: mode.maximumOutputBytes), err = OwnedPipeCapture(limit: 16_384)
        var inputBytes = 0
        var inputClosed = false
        var inputCloseAttempted = false
        func closeInput() {
            guard !inputCloseAttempted else { return }
            inputCloseAttempted = true
            do { try inputWrite.close(); inputClosed = true }
            catch { inputClosed = false }
        }
        let admitted: Bool
        if case .admitted = admission { admitted = true } else { admitted = false }
        if !admitted {
            closeInput()
            child.requestTermination(now: DispatchTime.now().uptimeNanoseconds,
                                     timedOut: false, cancelled: false)
        }
        var writeFailed = false
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let terminal = child.pollTerminal()
            let cancelled = cancellation.isCancelled
            let timedOut = now >= stopWorkAt || cancellation.isDeadlineExceeded
            if !terminal, (cancelled || timedOut || !admitted || writeFailed) {
                closeInput()
                child.requestTermination(now: now, timedOut: timedOut, cancelled: cancelled)
            }
            if terminal { closeInput() }
            let consumedOut = out.drain(outputRead.fileDescriptor)
            let consumedErr = err.drain(errorRead.fileDescriptor)
            if !inputCloseAttempted, !cancelled, !timedOut {
                if inputBytes == standardInput.count { closeInput() }
                else {
                    let count = child.writeAdmitted(inputWrite.fileDescriptor, data: standardInput,
                        offset: inputBytes, cancellation: cancellation, stopWorkAt: stopWorkAt)
                    if let count {
                        if count > 0 { inputBytes += count }
                        else if count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                            writeFailed = true; closeInput()
                        }
                    } else {
                        closeInput()
                    }
                }
            }
            if terminal, out.end != nil, err.end != nil { break }
            if now >= end {
                closeInput()
                child.forceTerminationAtDeadline(cancelled: cancelled)
                break
            }
            if consumedOut || consumedErr { continue }
            var descriptors = [
                pollfd(fd: out.end == nil ? outputRead.fileDescriptor : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: err.end == nil ? errorRead.fileDescriptor : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputCloseAttempted ? -1 : inputWrite.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            ]
            _ = Darwin.poll(&descriptors, nfds_t(descriptors.count),
                            Int32(min(25, max(1, (end - now) / 1_000_000))))
        }
        let confirmed = child.pollTerminal()
        let status = child.snapshot()
        guard confirmed else {
            throw OwnedNativeTerminationUnconfirmed(processIdentifier: pid,
                signalError: status.signalError, waitError: status.waitError,
                killRequested: status.killRequested)
        }
        return OwnedDuplexResult(exitCode: status.exitCode, terminationSignal: status.signal,
            stdout: out.finish(), stderr: err.finish(), stdinBytesWritten: inputBytes,
            stdinClosed: inputClosed, admission: admission, timedOut: status.timedOut,
            cancelled: status.cancelled, termRequested: status.termAt != nil,
            killRequested: status.killRequested, terminationConfirmed: confirmed)
    }

    /// One bounded recovery of this runner's retained owner; never starts a child.
    func shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: UInt64) -> Bool {
        ownedModeLock.lock()
        guard !ownedModeReserved else { ownedModeLock.unlock(); return false }
        let child = ownedModeChild
        ownedModeReserved = true
        ownedModeLock.unlock()
        defer {
            ownedModeLock.lock()
            if child?.snapshot().exitCode != nil { ownedModeChild = nil }
            ownedModeReserved = false
            ownedModeLock.unlock()
        }
        guard let child else { return true }
        let end = min(deadlineUptimeNanoseconds, DispatchTime.now().uptimeNanoseconds + 1_500_000_000)
        while !child.pollTerminal() {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= end { return false }
            child.requestTermination(now: now, timedOut: true, cancelled: true)
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}

/// Failures that are specific to subprocess lifecycle management.
public enum ProcessRunnerError: Error, Equatable, Sendable, LocalizedError {
    /// TERM and KILL were requested, but process termination was not observed before
    /// the final bounded wait expired. No termination status is available in this state.
    case terminationUnconfirmed(processIdentifier: Int32, signalError: Int32?)

    public var errorDescription: String? {
        switch self {
        case let .terminationUnconfirmed(pid, signalError):
            if let signalError {
                return "process \(pid) did not confirm termination; SIGKILL failed with errno \(signalError)"
            }
            return "process \(pid) did not confirm termination after SIGKILL"
        }
    }
}

/// Runs native processes with timeout (no implicit shell injection — argv array).
///
/// Multiplexes nonblocking stdout/stderr reads so large or chatty children cannot
/// deadlock on full pipe buffers while control checks retain a bounded cadence.
public final class ProcessRunner: @unchecked Sendable {
    private let terminationGraceSec: TimeInterval
    private let forcedTerminationGraceSec: TimeInterval
    private let maximumRetainedOutputBytes: Int
    private let inheritEnvironment: Bool
    private let ownedModeLock = NSLock()
    private var ownedModeReserved = false
    private var ownedModeChild: OwnedNativeChild?

    public init(inheritEnvironment: Bool = true) {
        self.inheritEnvironment = inheritEnvironment
        terminationGraceSec = 0.5
        forcedTerminationGraceSec = 1.0
        maximumRetainedOutputBytes = ResourcePolicy.current.nominalLimits.processOutputBytesPerStream
    }

    /// Internal timing seam keeps timeout-path tests fast without changing production bounds.
    init(
        terminationGraceSec: TimeInterval,
        forcedTerminationGraceSec: TimeInterval,
        maximumRetainedOutputBytes: Int = ResourcePolicy.current.nominalLimits.processOutputBytesPerStream
    ) {
        inheritEnvironment = true
        self.terminationGraceSec = max(0, terminationGraceSec)
        self.forcedTerminationGraceSec = max(0, forcedTerminationGraceSec)
        self.maximumRetainedOutputBytes = max(0, maximumRetainedOutputBytes)
    }

    public func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeoutSec: TimeInterval = 30,
        maximumOutputBytes: Int = 1_048_576,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProcessResult {
        try cancellation?.checkCancellation()
        var exeURL: URL
        if executable.hasPrefix("/") {
            exeURL = URL(fileURLWithPath: executable)
        } else if let path = ProcessRunner.which(executable) {
            exeURL = URL(fileURLWithPath: path)
        } else {
            throw NSError(
                domain: "ProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "executable not found: \(executable)"]
            )
        }

        let effectiveArguments = arguments
        let effectiveDirectory = currentDirectory
        let effectiveEnvironment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()

        // Both descriptors belong exclusively to this invocation. Bounded,
        // alternating nonblocking reads remove callback cancellation waits and
        // prevent a chatty stream from starving the other stream or control checks.
        final class BufferBox {
            var data = Data()
            var truncated = false
            var reachedEOF = false
            let limit: Int
            private var buffer = [UInt8](repeating: 0, count: 16_384)

            init(limit: Int) { self.limit = limit }

            @discardableResult
            func drain(_ handle: FileHandle, maximumReads: Int = 8, final: Bool = false) -> Bool {
                guard !reachedEOF else { return false }
                var consumed = false
                for _ in 0..<maximumReads {
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        consumed = true
                        let retained = min(max(0, limit - data.count), count)
                        if retained > 0 { data.append(contentsOf: buffer.prefix(retained)) }
                        if retained < count { truncated = true }
                        // Continue discarding after the retention cap: stopping reads
                        // here could prevent a finite child from reaching its exit.
                        continue
                    }
                    if count == 0 { reachedEOF = true; return consumed }
                    if errno == EINTR { continue } // Included in this finite read budget.
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        truncated = true
                        reachedEOF = true
                    }
                    return consumed
                }
                if final { truncated = true }
                return consumed
            }

            func take() -> (data: Data, truncated: Bool) { (data, truncated) }
        }

        let boundedOutputBytes = min(max(0, maximumOutputBytes), maximumRetainedOutputBytes)
        let outBox = BufferBox(limit: boundedOutputBytes)
        let errBox = BufferBox(limit: boundedOutputBytes)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outWriteHandle = outPipe.fileHandleForWriting
        let errWriteHandle = errPipe.fileHandleForWriting

        var outputFinalized = false
        func finalizeOutput(drain: Bool) -> (
            stdout: (data: Data, truncated: Bool),
            stderr: (data: Data, truncated: Bool)
        ) {
            if drain {
                // Only already-readable bytes are collected after the terminal
                // result. An escaped descendant cannot force an EOF wait.
                outBox.drain(outHandle, maximumReads: 512, final: true)
                errBox.drain(errHandle, maximumReads: 512, final: true)
            }
            try? outHandle.close()
            try? errHandle.close()
            outputFinalized = true
            return (outBox.take(), errBox.take())
        }
        defer {
            try? outWriteHandle.close()
            try? errWriteHandle.close()
            if !outputFinalized {
                _ = finalizeOutput(drain: false)
            }
        }

        for handle in [outHandle, errHandle] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        let processIdentifier: Int32
        do {
            processIdentifier = try Self.spawn(
                executable: exeURL,
                arguments: effectiveArguments,
                currentDirectory: effectiveDirectory,
                environment: effectiveEnvironment,
                inheritEnvironment: inheritEnvironment,
                stdoutDescriptors: [outHandle.fileDescriptor, outWriteHandle.fileDescriptor],
                stderrDescriptors: [errHandle.fileDescriptor, errWriteHandle.fileDescriptor]
            )
        } catch {
            throw error
        }
        // The parent must not retain write ends; otherwise EOF can never be observed
        // after the owned process group has exited.
        try? outWriteHandle.close()
        try? errWriteHandle.close()

        let runtimeDiagnostics = RuntimeDiagnostics.shared
        let operation = UInt64(UInt32(bitPattern: processIdentifier))
        runtimeDiagnostics.increment(.processLaunches)
        runtimeDiagnostics.adjust(.childProcesses, by: 1)
        runtimeDiagnostics.adjust(.processReaders, by: 2)
        let processSignpost = RuntimeSignposts.processLaunch(operation: operation)
        defer {
            runtimeDiagnostics.adjust(.processReaders, by: -2)
            runtimeDiagnostics.adjust(.childProcesses, by: -1)
            runtimeDiagnostics.increment(.processExits)
            RuntimeSignposts.processExit(processSignpost, operation: operation)
        }

        var terminationSignal: Int32?
        func pollTerminalStatus() throws -> Int32? {
            var rawStatus: Int32 = 0
            var waited: pid_t
            var interruptions = 0
            repeat {
                waited = Darwin.waitpid(processIdentifier, &rawStatus, WNOHANG)
                interruptions += 1
            } while waited < 0 && errno == EINTR && interruptions < 8
            if waited == 0 || (waited < 0 && errno == EINTR) { return nil }
            guard waited == processIdentifier else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "waitpid failed for process \(processIdentifier): \(String(cString: strerror(errno)))",
                    ]
                )
            }
            let signal = rawStatus & 0x7f
            terminationSignal = signal == 0 ? nil : signal
            return signal == 0 ? (rawStatus >> 8) & 0xff : signal
        }

        func processGroupExists() -> Bool {
            let result = Darwin.kill(-processIdentifier, 0)
            return result == 0 || errno == EPERM
        }

        @discardableResult
        func signalOwnedProcess(_ signal: Int32, includeDirectChild: Bool) -> Int32? {
            var signalError: Int32?
            if Darwin.kill(-processIdentifier, signal) != 0, errno != ESRCH {
                signalError = errno
            }
            // POSIX_SPAWN_SETPGROUP makes the child the process-group leader. The
            // direct signal is a bounded fallback if the executable changed groups.
            if includeDirectChild,
               Darwin.kill(processIdentifier, signal) != 0,
               errno != ESRCH,
               signalError == nil {
                signalError = errno
            }
            return signalError
        }

        func waitForOwnedExit(
            status: inout Int32?,
            maximumSeconds: TimeInterval
        ) throws -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, maximumSeconds)
            while true {
                // A TERM handler can flush output before exiting. Keep servicing
                // both pipes through the existing finite termination deadline.
                outBox.drain(outHandle)
                errBox.drain(errHandle)
                if status == nil {
                    status = try pollTerminalStatus()
                }
                if status != nil, !processGroupExists() { return true }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { return status != nil && !processGroupExists() }
                Thread.sleep(forTimeInterval: min(0.025, remaining))
            }
        }

        func terminateAndConfirm(initialStatus: Int32?) throws -> Int32 {
            var status = initialStatus
            _ = signalOwnedProcess(SIGTERM, includeDirectChild: status == nil)
            if try waitForOwnedExit(status: &status, maximumSeconds: terminationGraceSec),
               let status {
                return status
            }
            // Some commands and their descendants ignore SIGTERM. SIGKILL is sent to
            // the owned group, then both direct-child reaping and group disappearance
            // are confirmed before returning control to the caller.
            let signalError = signalOwnedProcess(SIGKILL, includeDirectChild: status == nil)
            guard try waitForOwnedExit(status: &status, maximumSeconds: forcedTerminationGraceSec),
                  let status else {
                throw ProcessRunnerError.terminationUnconfirmed(
                    processIdentifier: processIdentifier,
                    signalError: signalError
                )
            }
            return status
        }

        func closeDescendantsAfterTerminal(_ status: Int32) throws {
            guard processGroupExists() else { return }
            var terminalStatus: Int32? = status
            _ = signalOwnedProcess(SIGTERM, includeDirectChild: false)
            if try waitForOwnedExit(
                status: &terminalStatus,
                maximumSeconds: terminationGraceSec
            ) {
                return
            }
            let signalError = signalOwnedProcess(SIGKILL, includeDirectChild: false)
            guard try waitForOwnedExit(
                status: &terminalStatus,
                maximumSeconds: forcedTerminationGraceSec
            ) else {
                throw ProcessRunnerError.terminationUnconfirmed(
                    processIdentifier: processIdentifier,
                    signalError: signalError
                )
            }
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let boundedTimeout: TimeInterval
        // Preserve the prior bounded adapter contract: every non-finite or negative
        // timeout is an immediate timeout. No caller can turn the shared process
        // boundary into an indefinite wait by supplying positive infinity.
        boundedTimeout = timeoutSec.isFinite ? max(0, timeoutSec) : 0
        let timeoutDeadline = startedAt + boundedTimeout
        var exitCode: Int32?
        var controlError: Error?
        var timedOut = false
        var readStdoutNext = true

        while exitCode == nil {
            // A directly observed terminal result is authoritative. Checking it both
            // before and immediately after control state closes the cancellation race
            // without ever reporting a rollback for an already-completed command.
            exitCode = try pollTerminalStatus()
            if exitCode != nil { break }

            do {
                try cancellation?.checkCancellation()
            } catch {
                exitCode = try pollTerminalStatus()
                if exitCode == nil { controlError = error }
            }
            if exitCode != nil || controlError != nil { break }

            let now = ProcessInfo.processInfo.systemUptime
            if now >= timeoutDeadline {
                exitCode = try pollTerminalStatus()
                if exitCode == nil { timedOut = true }
                break
            }

            var remaining = timeoutDeadline - now
            if let controlRemaining = cancellation?.remainingTimeInterval {
                remaining = min(remaining, controlRemaining)
            }
            let consumed = readStdoutNext ? outBox.drain(outHandle) : errBox.drain(errHandle)
            readStdoutNext.toggle()
            if consumed { continue }
            if remaining > 0 {
                var descriptors = [
                    pollfd(fd: outBox.reachedEOF ? -1 : outHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: errBox.reachedEOF ? -1 : errHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                ]
                _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), Int32(min(25, max(1, remaining * 1_000))))
            }
        }

        if let observed = exitCode {
            try closeDescendantsAfterTerminal(observed)
            exitCode = observed
        } else {
            exitCode = try terminateAndConfirm(initialStatus: nil)
        }

        let captured = finalizeOutput(drain: true)
        if let controlError { throw controlError }

        return ProcessResult(
            exitCode: exitCode ?? 255,
            stdout: String(decoding: captured.stdout.data, as: UTF8.self),
            stderr: String(decoding: captured.stderr.data, as: UTF8.self),
            timedOut: timedOut,
            stdoutTruncated: captured.stdout.truncated,
            stderrTruncated: captured.stderr.truncated,
            terminationSignal: terminationSignal
        )
    }

    private static func spawn(
        executable: URL,
        arguments: [String],
        currentDirectory: String?,
        environment suppliedEnvironment: [String: String]?,
        inheritEnvironment: Bool,
        stdoutDescriptors: [Int32],
        stderrDescriptors: [Int32],
        stdinDescriptors: [Int32]? = nil
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw posixError(result, operation: "initialize spawn actions") }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw posixError(result, operation: "initialize spawn attributes")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        result = posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO)
        guard result == 0 else { throw posixError(result, operation: "configure stdout") }
        result = posix_spawn_file_actions_adddup2(&actions, stderrDescriptors[1], STDERR_FILENO)
        guard result == 0 else { throw posixError(result, operation: "configure stderr") }
        if let stdinDescriptors {
            result = posix_spawn_file_actions_adddup2(&actions, stdinDescriptors[0], STDIN_FILENO)
            guard result == 0 else { throw posixError(result, operation: "configure owned stdin") }
        }
        for descriptor in Set(stdoutDescriptors + stderrDescriptors + (stdinDescriptors ?? [])).sorted()
        where descriptor != STDIN_FILENO && descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else { throw posixError(result, operation: "close inherited pipe") }
        }
        if stdinDescriptors == nil {
            result = posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            )
            guard result == 0 else { throw posixError(result, operation: "configure stdin") }
        }
        if let currentDirectory {
            result = currentDirectory.withCString {
                posix_spawn_file_actions_addchdir(&actions, $0)
            }
            guard result == 0 else { throw posixError(result, operation: "configure working directory") }
        }

        var emptySignalMask = sigset_t()
        guard Darwin.sigemptyset(&emptySignalMask) == 0 else {
            throw posixError(errno, operation: "initialize signal mask")
        }
        result = posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        guard result == 0 else { throw posixError(result, operation: "configure signal mask") }
        var defaultSignals = sigset_t()
        guard Darwin.sigfillset(&defaultSignals) == 0 else {
            throw posixError(errno, operation: "initialize default signals")
        }
        result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard result == 0 else { throw posixError(result, operation: "configure default signals") }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        result = posix_spawnattr_setflags(&attributes, flags)
        guard result == 0 else { throw posixError(result, operation: "configure spawn flags") }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else { throw posixError(result, operation: "configure process group") }

        var mergedEnvironment = inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
        if let suppliedEnvironment {
            for (key, value) in suppliedEnvironment { mergedEnvironment[key] = value }
        }
        let argumentPointers = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = mergedEnvironment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argumentPointers where pointer != nil {
                Darwin.free(UnsafeMutableRawPointer(pointer!))
            }
            for pointer in environmentPointers where pointer != nil {
                Darwin.free(UnsafeMutableRawPointer(pointer!))
            }
        }

        var processIdentifier: pid_t = 0
        result = argumentPointers.withUnsafeBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &processIdentifier,
                    executable.path,
                    &actions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argumentBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: environmentBuffer.baseAddress)
                )
            }
        }
        guard result == 0 else { throw posixError(result, operation: "spawn process") }
        return processIdentifier
    }

    private static func posixError(_ code: Int32, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to \(operation): \(String(cString: strerror(code)))",
            ]
        )
    }

    public static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

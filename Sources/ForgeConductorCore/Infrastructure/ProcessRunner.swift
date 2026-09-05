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

/// Runs allowlisted processes with timeout (no shell injection — argv array).
///
/// Multiplexes nonblocking stdout/stderr reads so large or chatty children cannot
/// deadlock on full pipe buffers while control checks retain a bounded cadence.
public final class ProcessRunner: @unchecked Sendable {
    private let terminationGraceSec: TimeInterval
    private let forcedTerminationGraceSec: TimeInterval
    private let maximumRetainedOutputBytes: Int

    public init() {
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
        let exeURL: URL
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
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
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
            stderrTruncated: captured.stderr.truncated
        )
    }

    private static func spawn(
        executable: URL,
        arguments: [String],
        currentDirectory: String?,
        environment suppliedEnvironment: [String: String]?,
        stdoutDescriptors: [Int32],
        stderrDescriptors: [Int32]
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
        for descriptor in Set(stdoutDescriptors + stderrDescriptors).sorted()
        where descriptor != STDIN_FILENO && descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else { throw posixError(result, operation: "close inherited pipe") }
        }
        result = posix_spawn_file_actions_addopen(
            &actions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        )
        guard result == 0 else { throw posixError(result, operation: "configure stdin") }
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

        var mergedEnvironment = ProcessInfo.processInfo.environment
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

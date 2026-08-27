// main.swift
// Holds a runtime process behind a parent-owned launch gate until durable ownership is committed.

import Darwin

private enum LaunchProtocol {
    static let gateDescriptor: Int32 = 3
    static let releaseByte: UInt8 = 0xA5
    static let usageExit: Int32 = 64
    static let gateClosedExit: Int32 = 125
    static let executionFailureExit: Int32 = 126
    static let resourceLimitFailureExit: Int32 = 78
    static let maximumGateWaitNanoseconds: UInt64 = 60 * 1_000_000_000
}

private enum ResourceLimitEnvironment {
    static let cpuSeconds = "FORGE_RUNTIME_LIMIT_CPU_SECONDS"
    static let openFiles = "FORGE_RUNTIME_LIMIT_OPEN_FILES"
    static let fileBytes = "FORGE_RUNTIME_LIMIT_FILE_BYTES"
    static let coreBytes = "FORGE_RUNTIME_LIMIT_CORE_BYTES"

    static let defaultCPUSeconds: UInt64 = 4 * 60 * 60
    static let defaultOpenFiles: UInt64 = 256
    static let defaultFileBytes: UInt64 = 1_024 * 1_024 * 1_024
    static let defaultCoreBytes: UInt64 = 0
}

private func terminate(_ status: Int32) -> Never {
    Darwin._exit(status)
}

private func monotonicNanoseconds() -> UInt64? {
    var time = timespec()
    guard Darwin.clock_gettime(CLOCK_MONOTONIC, &time) == 0,
          time.tv_sec >= 0,
          time.tv_nsec >= 0 else { return nil }
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func environmentLimit(
    _ name: String,
    default defaultValue: UInt64,
    maximum: UInt64
) -> UInt64? {
    guard let pointer = Darwin.getenv(name) else { return defaultValue }
    let value = String(cString: pointer)
    guard let parsed = UInt64(value), parsed <= maximum else { return nil }
    return parsed
}

private func applyResourceLimit(_ resource: Int32, value: UInt64) -> Bool {
    var inherited = rlimit()
    guard Darwin.getrlimit(resource, &inherited) == 0 else { return false }
    let requested = rlim_t(value)
    let bounded: rlim_t
    let infinity = rlim_t.max >> 1
    if inherited.rlim_max == infinity {
        bounded = requested
    } else {
        bounded = min(requested, inherited.rlim_max)
    }
    var limit = rlimit(rlim_cur: bounded, rlim_max: bounded)
    return Darwin.setrlimit(resource, &limit) == 0
}

private func applyResourceLimits() -> Bool {
    guard let cpuSeconds = environmentLimit(
        ResourceLimitEnvironment.cpuSeconds,
        default: ResourceLimitEnvironment.defaultCPUSeconds,
        maximum: 24 * 60 * 60
    ),
    let openFiles = environmentLimit(
        ResourceLimitEnvironment.openFiles,
        default: ResourceLimitEnvironment.defaultOpenFiles,
        maximum: 4_096
    ),
    let fileBytes = environmentLimit(
        ResourceLimitEnvironment.fileBytes,
        default: ResourceLimitEnvironment.defaultFileBytes,
        maximum: 16 * 1_024 * 1_024 * 1_024
    ),
    let coreBytes = environmentLimit(
        ResourceLimitEnvironment.coreBytes,
        default: ResourceLimitEnvironment.defaultCoreBytes,
        maximum: 1_024 * 1_024 * 1_024
    ),
    cpuSeconds > 0,
    openFiles >= 16,
    fileBytes > 0 else { return false }

    // These limits are per process and inherited by its descendants. RLIMIT_NPROC
    // is deliberately not changed because Darwin accounts it per user, which could
    // interfere with unrelated applications owned by the same login session.
    return applyResourceLimit(RLIMIT_CPU, value: cpuSeconds)
        && applyResourceLimit(RLIMIT_NOFILE, value: openFiles)
        && applyResourceLimit(RLIMIT_FSIZE, value: fileBytes)
        && applyResourceLimit(RLIMIT_CORE, value: coreBytes)
}

private func awaitRelease(parent: pid_t) -> Bool {
    guard Darwin.fcntl(
        LaunchProtocol.gateDescriptor,
        F_SETFD,
        FD_CLOEXEC
    ) == 0,
    let started = monotonicNanoseconds() else { return false }
    let deadline = started.addingReportingOverflow(
        LaunchProtocol.maximumGateWaitNanoseconds
    )
    guard !deadline.overflow else { return false }
    var byte: UInt8 = 0
    while true {
        guard Darwin.getppid() == parent,
              let now = monotonicNanoseconds(),
              now < deadline.partialValue else { return false }
        let remaining = deadline.partialValue - now
        let remainingMilliseconds = max(UInt64(1), remaining / 1_000_000)
        let milliseconds = Int32(min(UInt64(Int32.max), remainingMilliseconds))
        var pollDescriptor = pollfd(
            fd: LaunchProtocol.gateDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
        if pollResult == 0 { return false }
        if pollResult < 0 {
            if errno == EINTR { continue }
            return false
        }
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            Darwin.read(
                LaunchProtocol.gateDescriptor,
                buffer.baseAddress,
                buffer.count
            )
        }
        if count == 1 {
            return byte == LaunchProtocol.releaseByte
        }
        if count < 0, errno == EINTR {
            continue
        }
        return false
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 5,
      arguments[1] == "--parent",
      let parent = pid_t(arguments[2]),
      parent > 1,
      arguments[3] == "--" else {
    terminate(LaunchProtocol.usageExit)
}
guard applyResourceLimits() else {
    terminate(LaunchProtocol.resourceLimitFailureExit)
}
guard awaitRelease(parent: parent) else {
    terminate(LaunchProtocol.gateClosedExit)
}
_ = Darwin.close(LaunchProtocol.gateDescriptor)
Darwin.unsetenv(ResourceLimitEnvironment.cpuSeconds)
Darwin.unsetenv(ResourceLimitEnvironment.openFiles)
Darwin.unsetenv(ResourceLimitEnvironment.fileBytes)
Darwin.unsetenv(ResourceLimitEnvironment.coreBytes)

let targetArguments = Array(arguments.dropFirst(4))
let pointers = targetArguments.map { strdup($0) } + [nil]
defer {
    for pointer in pointers where pointer != nil {
        Darwin.free(UnsafeMutableRawPointer(pointer!))
    }
}
let result = pointers.withUnsafeBufferPointer { buffer in
    Darwin.execv(
        targetArguments[0],
        UnsafeMutablePointer(mutating: buffer.baseAddress)
    )
}
_ = result
terminate(LaunchProtocol.executionFailureExit)

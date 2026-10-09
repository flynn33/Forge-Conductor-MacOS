import Foundation
import Darwin
import AudioToolbox

enum NativeAACM4AError: Error, Equatable { case busy, stopped, transport, unresolved, nativeFailure }

/// Value-only, versioned frames. No destination or application context enters the child.
enum AACM4AProtocol {
    static let maximumInputBytes = NativePCM16WAVWriter.maximumInputBytes
    static let maximumBase64Bytes = NativePCM16WAVWriter.maximumBase64Bytes
    static let maximumOutputBytes = NativePCM16WAVWriter.maximumOutputBytes
    static let maximumRequestBytes = 4 + 1_024 + maximumInputBytes
    static let maximumReplyBytes = 4 + 4_096 + maximumOutputBytes
    static let outputContract = "m4a-aac-lc-from-pcm16le-v1"
    struct Input: Sendable {
        let pcm: Data
        let rate: Int
        let channels: Int
        var frames: Int { pcm.count / (channels * 2) }
        var digest: String { JSONSupport.sha256Hex(pcm) }
    }
    struct Duration: Sendable, Equatable {
        let leading: Int
        let trailing: Int
        let packetFrames: Int
        func validate(_ frames: Int) throws {
            guard (0...16_384).contains(leading), (0...16_384).contains(trailing),
                  frames > 0, frames <= 524_288,
                  packetFrames == frames + leading + trailing else { throw NativeAACM4AError.transport }
        }
    }
    static func prepare(content: String, rate: Int, channels: Int,
                        cancellation: ToolCallCancellation?) throws -> Input {
        try cancellation?.checkCancellation()
        guard NativePCM16WAVWriter.sampleRates.contains(rate) else { throw NativePCM16WAVError.invalidSampleRate }
        guard channels == 1 || channels == 2 else { throw NativePCM16WAVError.invalidChannels }
        let count = try rawSize(content, cancellation: cancellation)
        guard count % (channels * 2) == 0 else { throw NativePCM16WAVError.incompleteFrames }
        guard let pcm = Data(base64Encoded: content), pcm.count == count,
              pcm.base64EncodedString() == content else { throw NativePCM16WAVError.internalMismatch }
        try cancellation?.checkCancellation()
        return Input(pcm: pcm, rate: rate, channels: channels)
    }
    private static func sextet(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 65...90: return byte - 65
        case 97...122: return byte - 97 + 26
        case 48...57: return byte - 48 + 52
        case 43: return 62
        case 47: return 63
        default: return nil
        }
    }
    private static func rawSize(_ content: String, cancellation: ToolCallCancellation?) throws -> Int {
        let count = content.utf8.prefix(maximumBase64Bytes + 1).count
        guard count <= maximumBase64Bytes else { throw NativePCM16WAVError.inputLimit }
        guard count > 0, count % 4 == 0 else { throw NativePCM16WAVError.invalidContent }
        let padding = content.hasSuffix("==") ? 2 : content.hasSuffix("=") ? 1 : 0
        let raw = (count / 4) * 3 - padding
        guard raw > 0 else { throw NativePCM16WAVError.invalidContent }
        guard raw <= maximumInputBytes else { throw NativePCM16WAVError.inputLimit }
        var lastSextet: UInt8 = 0
        for (index, byte) in content.utf8.enumerated() {
            if index % 4096 == 0 { try cancellation?.checkCancellation() }
            if index >= count - padding {
                guard byte == 61 else { throw NativePCM16WAVError.invalidContent }
            } else {
                guard let value = sextet(byte) else { throw NativePCM16WAVError.invalidContent }
                lastSextet = value
            }
        }
        guard padding != 2 || lastSextet & 15 == 0,
              padding != 1 || lastSextet & 3 == 0 else { throw NativePCM16WAVError.invalidContent }
        try cancellation?.checkCancellation()
        return raw
    }
    static func packetCeiling(frames: Int, queriedFramesPerPacket: UInt32) throws -> Int {
        guard (1...524_288).contains(frames), queriedFramesPerPacket > 0, queriedFramesPerPacket <= 8_192 else {
            throw NativeAACM4AError.nativeFailure
        }
        let capacity = UInt64(frames) + 32_768, divisor = UInt64(queriedFramesPerPacket)
        let ceiling = (capacity + divisor - 1) / divisor
        guard ceiling > 0, ceiling <= 1_024, let value = Int(exactly: ceiling) else { throw NativeAACM4AError.nativeFailure }
        return value
    }
    static func request(_ input: Input) throws -> Data {
        try validate(input)
        return try frame(metadata: ["version": 1, "sample_rate": input.rate, "channels": input.channels,
            "frames": input.frames, "pcm_bytes": input.pcm.count, "pcm_sha256": input.digest],
            body: input.pcm, metadataLimit: 1_024)
    }
    static func decodeRequest(_ data: Data) throws -> Input {
        let (m, body) = try unframe(data, limit: maximumRequestBytes, metadataLimit: 1_024)
        guard Set(m.keys) == Set(["version", "sample_rate", "channels", "frames", "pcm_bytes", "pcm_sha256"]),
              JSONSupport.exactInteger(m["version"]) == 1,
              let rate = JSONSupport.exactInteger(m["sample_rate"]),
              let channels = JSONSupport.exactInteger(m["channels"]) else { throw NativeAACM4AError.transport }
        let input = Input(pcm: body, rate: rate, channels: channels)
        try validate(input)
        guard JSONSupport.exactInteger(m["frames"]) == input.frames,
              JSONSupport.exactInteger(m["pcm_bytes"]) == body.count,
              m["pcm_sha256"] as? String == input.digest else { throw NativeAACM4AError.transport }
        return input
    }
    static func reply(input: Input, encoded: Data, duration: Duration) throws -> Data {
        try validate(input); try duration.validate(input.frames); try validateContainer(encoded)
        return try frame(metadata: ["version": 1, "sample_rate": input.rate, "channels": input.channels,
            "frames": input.frames, "pcm_bytes": input.pcm.count, "pcm_sha256": input.digest,
            "encoded_bytes": encoded.count, "encoded_sha256": JSONSupport.sha256Hex(encoded),
            "codec": "aac-lc", "container": "m4a", "priming_frames": duration.leading,
            "remainder_frames": duration.trailing, "packet_frame_sum": duration.packetFrames],
            body: encoded, metadataLimit: 4_096)
    }
    static func decodeReply(_ data: Data, input: Input) throws -> Data {
        try validate(input)
        let (m, body) = try unframe(data, limit: maximumReplyBytes, metadataLimit: 4_096)
        guard Set(m.keys) == Set(["version", "sample_rate", "channels", "frames", "pcm_bytes", "pcm_sha256",
            "encoded_bytes", "encoded_sha256", "codec", "container", "priming_frames", "remainder_frames", "packet_frame_sum"]),
              JSONSupport.exactInteger(m["version"]) == 1,
              JSONSupport.exactInteger(m["sample_rate"]) == input.rate,
              JSONSupport.exactInteger(m["channels"]) == input.channels,
              JSONSupport.exactInteger(m["frames"]) == input.frames,
              JSONSupport.exactInteger(m["pcm_bytes"]) == input.pcm.count,
              m["pcm_sha256"] as? String == input.digest,
              JSONSupport.exactInteger(m["encoded_bytes"]) == body.count,
              m["encoded_sha256"] as? String == JSONSupport.sha256Hex(body),
              m["codec"] as? String == "aac-lc", m["container"] as? String == "m4a",
              let leading = JSONSupport.exactInteger(m["priming_frames"]),
              let trailing = JSONSupport.exactInteger(m["remainder_frames"]),
              let frames = JSONSupport.exactInteger(m["packet_frame_sum"]) else { throw NativeAACM4AError.transport }
        try Duration(leading: leading, trailing: trailing, packetFrames: frames).validate(input.frames)
        try validateContainer(body)
        return body
    }
    private static func validate(_ input: Input) throws {
        guard NativePCM16WAVWriter.sampleRates.contains(input.rate), input.channels == 1 || input.channels == 2,
              !input.pcm.isEmpty, input.pcm.count <= maximumInputBytes,
              input.pcm.count % (input.channels * 2) == 0 else { throw NativeAACM4AError.transport }
    }
    private static func validateContainer(_ data: Data) throws {
        guard data.count >= 12, data.count <= maximumOutputBytes else { throw NativeAACM4AError.transport }
        let head = Array(data.prefix(8))
        let length = head.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 12, Int(length) <= data.count, Array(head.suffix(4)) == [102, 116, 121, 112] else {
            throw NativeAACM4AError.transport
        }
    }
    private static func frame(metadata: [String: Any], body: Data, metadataLimit: Int) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        guard !bytes.isEmpty, bytes.count <= metadataLimit else { throw NativeAACM4AError.transport }
        let n = UInt32(bytes.count)
        var output = Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                           UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        output.append(bytes); output.append(body); return output
    }
    private static func unframe(_ data: Data, limit: Int, metadataLimit: Int) throws -> ([String: Any], Data) {
        guard data.count >= 5, data.count <= limit else { throw NativeAACM4AError.transport }
        let length = Array(data.prefix(4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, Int(length) <= metadataLimit, Int(length) <= data.count - 4 else { throw NativeAACM4AError.transport }
        let metadata = Data(data.dropFirst(4).prefix(Int(length)))
        guard let value = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) == metadata else {
            throw NativeAACM4AError.transport
        }
        return (value, Data(data.dropFirst(4 + Int(length))))
    }
}

/// One operation and one owned runner. Unconfirmed termination retains the busy slot.
final class NativeAACM4AEncoder: @unchecked Sendable {
    typealias Run = @Sendable (Data, UInt64, ToolCallCancellation) throws -> OwnedDuplexResult
    typealias Recover = @Sendable (UInt64) -> Bool
    private struct Active {
        let id: UUID
        let cancellation: ToolCallCancellation
        let end: UInt64
        var inFlight = true
        var recovering = false
    }
    private let condition = NSCondition()
    private let run: Run
    private let recover: Recover
    private var active: Active?
    private var stopped = false
    init() {
        let runner = ProcessRunner(inheritEnvironment: false)
        run = { try runner.runOwnedCurrentSelf(mode: .aacM4AV1, standardInput: $0,
            deadlineUptimeNanoseconds: $1, cancellation: $2) }
        recover = { runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: $0) }
    }
    init(run: @escaping Run, recover: @escaping Recover) { self.run = run; self.recover = recover }
    func encode(content: String, sampleRate: Int, channels: Int,
                cancellation: ToolCallCancellation?) throws -> NativePCM16WAVWriter.EncodedAudio {
        guard !Thread.isMainThread else { throw NativePCM16WAVError.workerRequired }
        let control = cancellation ?? ToolCallCancellation(timeoutSeconds: 30)
        try control.checkCancellation()
        let seconds = min(30, control.remainingTimeInterval ?? 30)
        guard seconds > 2.5 else { throw ToolCallDeadlineExceeded() }
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000), id = UUID()
        condition.lock()
        guard !stopped, active == nil else {
            let error: NativeAACM4AError = stopped ? .stopped : .busy
            condition.unlock(); throw error
        }
        active = Active(id: id, cancellation: control, end: end); condition.unlock()
        var unresolved = false
        defer {
            condition.lock()
            if active?.id == id {
                if unresolved { active?.inFlight = false } else { active = nil }
            }
            condition.broadcast(); condition.unlock()
        }
        let input = try AACM4AProtocol.prepare(content: content, rate: sampleRate, channels: channels, cancellation: control)
        let request = try AACM4AProtocol.request(input)
        try control.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < end else { throw ToolCallDeadlineExceeded() }
        let result: OwnedDuplexResult
        do { result = try run(request, end, control) }
        catch let error as OwnedNativeTerminationUnconfirmed { unresolved = true; throw error }
        guard result.terminationConfirmed else { unresolved = true; throw NativeAACM4AError.unresolved }
        try control.checkCancellation()
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw ToolCallDeadlineExceeded() }
        guard result.admission == .admitted, result.terminationSignal == nil,
              !result.termRequested, !result.killRequested, result.stdinBytesWritten == request.count, result.stdinClosed,
              result.stdout.end == .eof, result.stderr.end == .eof,
              !result.stdout.truncated, !result.stderr.truncated, result.exitCode == 0 else { throw NativeAACM4AError.transport }
        let bytes = try AACM4AProtocol.decodeReply(result.stdout.data, input: input)
        try control.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < end else { throw ToolCallDeadlineExceeded() }
        return .init(data: bytes, sampleRate: sampleRate, channels: channels, frames: input.frames, pcmBytes: input.pcm.count)
    }
    func shutdown() -> Bool {
        condition.lock(); stopped = true; active?.cancellation.cancel()
        while let operation = active, operation.inFlight {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < operation.end else { condition.unlock(); return false }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.05, Double(operation.end - now) / 1_000_000_000)))
        }
        guard let operation = active else { condition.unlock(); return true }
        guard !operation.recovering else { condition.unlock(); return false }
        active?.recovering = true; condition.unlock()
        let confirmed = recover(operation.end)
        condition.lock()
        if active?.id == operation.id {
            if confirmed { active = nil } else { active?.recovering = false }
        }
        condition.broadcast(); condition.unlock(); return confirmed
    }
}

private let encodedCap = AACM4AProtocol.maximumOutputBytes
private let callbackBytesCap: UInt64 = 67_108_864
private final class Lifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func released() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
// A single strong owner holds both callback arena and converter I/O backing.
// AudioFile gives no Swift release callback; successful native Close is a separate witness.
private final class CallbackFile: @unchecked Sendable {
    private let lock = NSLock()
    private let arena: UnsafeMutableRawPointer
    let ioBuffer: UnsafeMutableRawPointer
    private let life: Lifetime, readonly: Bool, workStop: UInt64
    private var cleanupStop: UInt64?, size = 0
    private var calls = 0, requestedBytes: UInt64 = 0, firstError: String?
    private var structuralFailure = false
    init(bytes: Data?, life: Lifetime, workStop: UInt64) {
        precondition((bytes?.count ?? 0) <= encodedCap)
        self.life = life; readonly = bytes != nil; self.workStop = workStop
        arena = .allocate(byteCount: encodedCap, alignment: 8)
        arena.initializeMemory(as: UInt8.self, repeating: 0, count: encodedCap)
        ioBuffer = .allocate(byteCount: 32_768, alignment: 8)
        ioBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: 32_768)
        if let bytes {
            size = bytes.count
            bytes.withUnsafeBytes { source in
                if !bytes.isEmpty { arena.copyMemory(from: source.baseAddress!, byteCount: bytes.count) }
            }
        }
    }
    deinit { ioBuffer.deallocate(); arena.deallocate(); life.released() }
    private func fail(_ reason: String, structural: Bool = false) -> OSStatus {
        if firstError == nil { firstError = reason }; structuralFailure = structuralFailure || structural
        return kAudioFileUnspecifiedError
    }
    private func admit(_ count: UInt64, valid: Bool, reason: String) -> Bool {
        guard calls < 8192 else { _ = fail("callback_call_cap", structural: true); return false }
        calls += 1
        guard count <= UInt64(encodedCap), requestedBytes <= callbackBytesCap - count else {
            _ = fail("callback_byte_cap", structural: true); return false
        }
        requestedBytes += count
        guard valid else { _ = fail(reason, structural: true); return false }
        guard !structuralFailure else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if let cleanupStop {
            guard now < cleanupStop else { _ = fail("cleanup_deadline"); return false }
        } else {
            guard firstError == nil, now < workStop else { _ = fail("work_deadline"); return false }
        }
        return true
    }
    func beginCleanup(until: UInt64) { lock.lock(); cleanupStop = until; lock.unlock() }
    func read(position: Int64, count: UInt32, buffer: UnsafeMutableRawPointer, actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; actual.pointee = 0
        guard admit(UInt64(count), valid: position >= 0 && position <= Int64(encodedCap), reason: "read_position") else { return kAudioFileUnspecifiedError }
        let start = Int(position), copied = min(Int(count), max(0, size - start))
        if copied > 0 { buffer.copyMemory(from: arena.advanced(by: start), byteCount: copied) }
        actual.pointee = UInt32(copied); return noErr
    }
    func write(position: Int64, count: UInt32, buffer: UnsafeRawPointer, actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; actual.pointee = 0
        let valid = !readonly && position >= 0 && position <= Int64(encodedCap)
            && UInt64(count) <= UInt64(encodedCap) - UInt64(position)
        let gap = valid && position > Int64(size) ? UInt64(position - Int64(size)) : 0
        guard admit(UInt64(count) + gap, valid: valid, reason: "write_extent") else { return kAudioFileUnspecifiedError }
        let start = Int(position), end = start + Int(count)
        if start > size { arena.advanced(by: size).initializeMemory(as: UInt8.self, repeating: 0, count: start - size) }
        if count > 0 { arena.advanced(by: start).copyMemory(from: buffer, byteCount: Int(count)) }
        size = max(size, end); actual.pointee = count; return noErr
    }
    func getSize() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard admit(0, valid: true, reason: "get_size") else { return 0 }; return Int64(size)
    }
    func setSize(_ next: Int64) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let valid = !readonly && next >= 0 && next <= Int64(encodedCap)
        let growth = valid && next > Int64(size) ? UInt64(next - Int64(size)) : 0
        guard admit(growth, valid: valid, reason: "set_size") else { return kAudioFileUnspecifiedError }
        if next > Int64(size) { arena.advanced(by: size).initializeMemory(as: UInt8.self, repeating: 0, count: Int(next) - size) }
        size = Int(next); return noErr
    }
    func bytes() -> Data { lock.lock(); defer { lock.unlock() }; return Data(bytes: arena, count: size) }
    func healthy() -> Bool { lock.lock(); defer { lock.unlock() }; return firstError == nil && !structuralFailure }

}
private let readProc: AudioFile_ReadProc = { opaque, position, count, buffer, actual in
    Unmanaged<CallbackFile>.fromOpaque(opaque).takeUnretainedValue().read(position: position, count: count, buffer: buffer, actual: actual)
}
private let writeProc: AudioFile_WriteProc = { opaque, position, count, buffer, actual in
    Unmanaged<CallbackFile>.fromOpaque(opaque).takeUnretainedValue().write(position: position, count: count, buffer: buffer, actual: actual)
}
private let sizeProc: AudioFile_GetSizeProc = { opaque in Unmanaged<CallbackFile>.fromOpaque(opaque).takeUnretainedValue().getSize() }
private let setSizeProc: AudioFile_SetSizeProc = { opaque, count in Unmanaged<CallbackFile>.fromOpaque(opaque).takeUnretainedValue().setSize(count) }


// The immutable PCM and both opaque-cookie banks remain pinned until converter/file closure.
private final class PCMFeed: @unchecked Sendable {
    private let lock = NSLock(), pcm: UnsafeMutableRawPointer
    private let cookies: [UnsafeMutableRawPointer], life: Lifetime, channels: UInt32, frames: UInt32, count: Int, stop: UInt64
    private var calls = 0, cursor: UInt32 = 0, eofCalls = 0, requestedBytes: UInt64 = 0, firstError: String?
    init(_ f: AACM4AProtocol.Input, life: Lifetime, stop: UInt64) {
        self.life = life; channels = UInt32(f.channels); frames = UInt32(f.frames); count = f.pcm.count; self.stop = stop
        pcm = .allocate(byteCount: count, alignment: 8)
        cookies = (0..<2).map { _ in
            let p = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 8)
            p.initializeMemory(as: UInt8.self, repeating: 0, count: 65_536); return p
        }
        f.pcm.withUnsafeBytes { pcm.copyMemory(from: $0.baseAddress!, byteCount: count) }
    }
    deinit { cookies.forEach { $0.deallocate() }; pcm.deallocate(); life.released() }
    func cookie(_ bank: Int) -> UnsafeMutableRawPointer { cookies[bank] }
    func feed(packets: UnsafeMutablePointer<UInt32>, buffers: UnsafeMutablePointer<AudioBufferList>, descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        let wanted = packets.pointee; packets.pointee = 0
        buffers.pointee.mNumberBuffers = 1
        buffers.pointee.mBuffers = AudioBuffer(mNumberChannels: channels, mDataByteSize: 0, mData: pcm)
        descriptions?.pointee = nil // Fixed PCM packets need no descriptions.
        func fail(_ reason: String) -> OSStatus { if firstError == nil { firstError = reason }; return kAudioConverterErr_UnspecifiedError }
        guard calls < 8192 else { return fail("input_callback_count") }; calls += 1
        guard firstError == nil, DispatchTime.now().uptimeNanoseconds < stop else { return fail("input_callback_deadline/error") }
        guard wanted <= 1_048_576 / (channels * 2) else { return fail("input_request_count") }
        let requested = UInt64(wanted) * UInt64(channels * 2)
        guard requestedBytes <= callbackBytesCap - requested else { return fail("input_request_bytes") }; requestedBytes += requested
        if cursor == frames { eofCalls += 1; return noErr }
        guard wanted > 0, cursor < frames else { return fail("input_packet_extent") }
        let offered = min(wanted, frames - cursor), bytes = offered * channels * 2, offset = cursor * channels * 2
        buffers.pointee.mBuffers = AudioBuffer(mNumberChannels: channels, mDataByteSize: bytes, mData: pcm.advanced(by: Int(offset)))
        cursor += offered; packets.pointee = offered; return noErr
    }
    func complete(expected: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cursor == frames && eofCalls > 0 && firstError == nil && Data(bytes: pcm, count: count) == expected
    }

}
private let inputProc: AudioConverterComplexInputDataProc = { _, packets, buffers, descriptions, opaque in
    guard let opaque else { packets.pointee = 0; return kAudioConverterErr_UnspecifiedError }
    return Unmanaged<PCMFeed>.fromOpaque(opaque).takeUnretainedValue().feed(packets: packets, buffers: buffers, descriptions: descriptions)
}

/// Call-local child ownership. Ambiguous handles never escape or get blindly retried.
private final class AACChildRetentions {
    var owner: CallbackFile?
    var feed: PCMFeed?
    var converter: AudioConverterRef?
    var file: AudioFileID?
    var reader: CallbackFile?
    var readFile: AudioFileID?
    var converterStatus: OSStatus?
    var fileStatus: OSStatus?
    var readStatus: OSStatus?
    var ambiguous = false
}
private final class AACSession {
    let workStop: UInt64
    let cleanupStop: UInt64
    init(end: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        workStop = min(end > 5_000_000_000 ? end - 5_000_000_000 : 0, now + 25_000_000_000)
        cleanupStop = min(end, workStop + 2_000_000_000)
    }
    private var workCalls = 0, cleanupCalls = 0, workLimit = 64
    private(set) var cleanupHealthy = true
    func healthy() throws {
        guard !Thread.isMainThread, DispatchTime.now().uptimeNanoseconds < workStop else { throw ToolCallDeadlineExceeded() }
    }
    func setPacketLimit(_ limit: Int) throws {
        guard (1...1_024).contains(limit) else { throw NativeAACM4AError.nativeFailure }
        workLimit = 2 * limit + 64
    }
    func call(_ body: () -> OSStatus) throws -> OSStatus {
        try healthy()
        guard workCalls < workLimit else { throw NativeAACM4AError.nativeFailure }
        workCalls += 1
        let status = body()
        try healthy()
        guard status == noErr else { throw NativeAACM4AError.nativeFailure }
        return status
    }
    func optionalCall(_ body: () -> OSStatus) throws -> OSStatus {
        try healthy()
        guard workCalls < workLimit else { throw NativeAACM4AError.nativeFailure }
        workCalls += 1; let status = body(); try healthy(); return status
    }
    func close(_ body: () -> OSStatus) -> Bool {
        guard !Thread.isMainThread, cleanupCalls < 5,
              DispatchTime.now().uptimeNanoseconds < cleanupStop else { cleanupHealthy = false; return false }
        cleanupCalls += 1
        let status = body()
        let good = status == noErr && DispatchTime.now().uptimeNanoseconds < cleanupStop
        cleanupHealthy = cleanupHealthy && good
        return good
    }
    func converterProperty<T>(_ converter: AudioConverterRef, _ key: AudioConverterPropertyID, initial: T) throws -> T {
        var size: UInt32 = 0, value = initial
        _ = try call { AudioConverterGetPropertyInfo(converter, key, &size, nil) }
        guard MemoryLayout<T>.size <= 40, size == UInt32(MemoryLayout<T>.size) else { throw NativeAACM4AError.nativeFailure }
        _ = try withUnsafeMutablePointer(to: &value) { p in try call { AudioConverterGetProperty(converter, key, &size, p) } }
        guard size == UInt32(MemoryLayout<T>.size) else { throw NativeAACM4AError.nativeFailure }
        return value
    }
    func fileProperty<T>(_ file: AudioFileID, _ key: AudioFilePropertyID, initial: T) throws -> T {
        var size: UInt32 = 0, value = initial
        _ = try call { AudioFileGetPropertyInfo(file, key, &size, nil) }
        guard MemoryLayout<T>.size <= 40, size == UInt32(MemoryLayout<T>.size) else { throw NativeAACM4AError.nativeFailure }
        _ = try withUnsafeMutablePointer(to: &value) { p in try call { AudioFileGetProperty(file, key, &size, p) } }
        guard size == UInt32(MemoryLayout<T>.size) else { throw NativeAACM4AError.nativeFailure }
        return value
    }
    func cookie(_ converter: AudioConverterRef, file: AudioFileID, feed: PCMFeed, bank: Int) throws {
        var size: UInt32 = 0
        let status = try optionalCall { AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, nil) }
        if status == kAudioConverterErr_PropertyNotSupported { return }
        guard status == noErr, size <= 65_536 else { throw NativeAACM4AError.nativeFailure }
        if size == 0 { return }
        let capacity = size, p = feed.cookie(bank)
        _ = try call { AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, p) }
        guard size > 0, size <= capacity else { throw NativeAACM4AError.nativeFailure }
        _ = try call { AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, size, p) }
    }
}

private enum AACChildCodec {
    static func encode(_ input: AACM4AProtocol.Input, end: UInt64, retaining r: AACChildRetentions) throws -> (Data, AACM4AProtocol.Duration) {
        let session = AACSession(end: end)
        try session.healthy()
        let ownerLife = Lifetime(), feedLife = Lifetime()
        r.owner = CallbackFile(bytes: nil, life: ownerLife, workStop: session.workStop)
        r.feed = PCMFeed(input, life: feedLife, stop: session.workStop)
        weak var weakOwner = r.owner; weak var weakFeed = r.feed
        var failure: Error?, duration: AACM4AProtocol.Duration?, packets = 0, packetFrames: UInt64 = 0
        var queriedPacketFrames: UInt32 = 0
        do {
            let channels = UInt32(input.channels)
            var pcm = AudioStreamBasicDescription(mSampleRate: Double(input.rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channels * 2, mFramesPerPacket: 1, mBytesPerFrame: channels * 2,
                mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
            // Retained creation hint; every ceiling uses the queried normalized packet duration.
            var seed = AudioStreamBasicDescription(mSampleRate: Double(input.rate), mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: kAudioFormatFlagsAreAllClear, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
            _ = try withUnsafePointer(to: &pcm) { ip in try withUnsafePointer(to: &seed) { op in try session.call {
                r.converterStatus = AudioConverterNew(ip, op, &r.converter); return r.converterStatus!
            } } }
            guard r.converterStatus == noErr, let converter = r.converter else { throw NativeAACM4AError.nativeFailure }
            let ci = try session.converterProperty(converter, kAudioConverterCurrentInputStreamDescription, initial: AudioStreamBasicDescription())
            var actual = try session.converterProperty(converter, kAudioConverterCurrentOutputStreamDescription, initial: AudioStreamBasicDescription())
            guard ci.mSampleRate == pcm.mSampleRate, ci.mFormatID == pcm.mFormatID, ci.mFormatFlags == pcm.mFormatFlags,
                  ci.mBytesPerPacket == pcm.mBytesPerPacket, ci.mFramesPerPacket == 1, ci.mBytesPerFrame == pcm.mBytesPerFrame,
                  ci.mChannelsPerFrame == channels, ci.mBitsPerChannel == 16, ci.mReserved == 0,
                  actual.mFormatID == kAudioFormatMPEG4AAC, actual.mSampleRate == pcm.mSampleRate,
                  actual.mChannelsPerFrame == channels, actual.mFramesPerPacket > 0, actual.mFramesPerPacket <= 8_192,
                  actual.mReserved == 0 else { throw NativeAACM4AError.nativeFailure }
            queriedPacketFrames = actual.mFramesPerPacket
            let frameCap = UInt64(input.frames) + 32_768
            let writeLimit = try AACM4AProtocol.packetCeiling(frames: input.frames, queriedFramesPerPacket: queriedPacketFrames)
            try session.setPacketLimit(writeLimit)
            let maximum: UInt32 = try session.converterProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, initial: UInt32(0))
            guard maximum > 0, maximum <= 32_768 else { throw NativeAACM4AError.nativeFailure }
            _ = try withUnsafePointer(to: &actual) { p in try session.call {
                r.fileStatus = AudioFileInitializeWithCallbacks(Unmanaged.passUnretained(r.owner!).toOpaque(),
                    readProc, writeProc, sizeProc, setSizeProc, kAudioFileM4AType, p, AudioFileFlags(rawValue: 0), &r.file)
                return r.fileStatus!
            } }
            guard r.fileStatus == noErr, let file = r.file else { throw NativeAACM4AError.nativeFailure }
            try session.cookie(converter, file: file, feed: r.feed!, bank: 0)
            var drained = false
            for _ in 0...writeLimit {
                var count: UInt32 = 1, returned: UInt32 = 0, description = AudioStreamPacketDescription()
                _ = try session.call {
                    var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels,
                        mDataByteSize: maximum, mData: r.owner!.ioBuffer))
                    let status = AudioConverterFillComplexBuffer(converter, inputProc, Unmanaged.passUnretained(r.feed!).toOpaque(),
                        &count, &buffers, &description)
                    returned = buffers.mBuffers.mDataByteSize; return status
                }
                guard count <= 1, returned <= maximum, r.owner!.healthy() else { throw NativeAACM4AError.nativeFailure }
                if count == 0 {
                    guard returned == 0, r.feed!.complete(expected: input.pcm) else { throw NativeAACM4AError.nativeFailure }
                    drained = true; break
                }
                guard returned > 0, description.mStartOffset == 0, description.mDataByteSize == returned,
                      description.mVariableFramesInPacket <= queriedPacketFrames, packets < writeLimit else {
                    throw NativeAACM4AError.nativeFailure
                }
                var written: UInt32 = 1
                _ = try withUnsafePointer(to: &description) { p in try session.call {
                    AudioFileWritePackets(file, false, returned, p, Int64(packets), &written, r.owner!.ioBuffer)
                } }
                guard written == 1, r.owner!.healthy() else { throw NativeAACM4AError.nativeFailure }
                let n = description.mVariableFramesInPacket == 0 ? queriedPacketFrames : description.mVariableFramesInPacket
                guard n > 0, UInt64(n) <= frameCap, packetFrames <= frameCap - UInt64(n) else { throw NativeAACM4AError.nativeFailure }
                packetFrames += UInt64(n); packets += 1
            }
            guard drained, packets > 0 else { throw NativeAACM4AError.nativeFailure }
            var tail: UInt32 = 1, tailBytes: UInt32 = 0, tailDescription = AudioStreamPacketDescription()
            _ = try session.call {
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels,
                    mDataByteSize: maximum, mData: r.owner!.ioBuffer))
                let status = AudioConverterFillComplexBuffer(converter, inputProc, Unmanaged.passUnretained(r.feed!).toOpaque(),
                    &tail, &buffers, &tailDescription)
                tailBytes = buffers.mBuffers.mDataByteSize; return status
            }
            guard tail == 0, tailBytes == 0, r.feed!.complete(expected: input.pcm), r.owner!.healthy() else { throw NativeAACM4AError.nativeFailure }
            try session.cookie(converter, file: file, feed: r.feed!, bank: 1)
            let prime = try session.converterProperty(converter, kAudioConverterPrimeInfo, initial: AudioConverterPrimeInfo())
            let table = try session.fileProperty(file, kAudioFilePropertyPacketTableInfo, initial: AudioFilePacketTableInfo())
            guard prime.leadingFrames <= 16_384, prime.trailingFrames <= 16_384,
                  table.mNumberValidFrames >= 0, table.mNumberValidFrames <= Int64(frameCap),
                  (0...16_384).contains(table.mPrimingFrames), (0...16_384).contains(table.mRemainderFrames),
                  table.mNumberValidFrames + Int64(table.mPrimingFrames) + Int64(table.mRemainderFrames) == Int64(packetFrames) else {
                throw NativeAACM4AError.nativeFailure
            }
            let measured = AACM4AProtocol.Duration(leading: Int(prime.leadingFrames), trailing: Int(prime.trailingFrames), packetFrames: Int(packetFrames))
            try measured.validate(input.frames)
            var size: UInt32 = 0, writable: UInt32 = 0
            _ = try session.call { AudioFileGetPropertyInfo(file, kAudioFilePropertyPacketTableInfo, &size, &writable) }
            guard size == 16, MemoryLayout<AudioFilePacketTableInfo>.size == 16, writable == 1 else { throw NativeAACM4AError.nativeFailure }
            var proposed = AudioFilePacketTableInfo(mNumberValidFrames: Int64(input.frames),
                mPrimingFrames: Int32(measured.leading), mRemainderFrames: Int32(measured.trailing))
            _ = try withUnsafePointer(to: &proposed) { p in try session.call { AudioFileSetProperty(file, kAudioFilePropertyPacketTableInfo, 16, p) } }
            let verified = try session.fileProperty(file, kAudioFilePropertyPacketTableInfo, initial: AudioFilePacketTableInfo())
            guard sameTable(verified, measured: measured, frames: input.frames), r.owner!.healthy() else { throw NativeAACM4AError.nativeFailure }
            duration = measured
        } catch { failure = error }
        r.ambiguous = (r.converterStatus == noErr && r.converter == nil)
            || (r.converterStatus != nil && r.converterStatus != noErr && r.converter != nil)
            || (r.fileStatus == noErr && r.file == nil) || (r.fileStatus != nil && r.fileStatus != noErr && r.file != nil)
        r.owner?.beginCleanup(until: session.cleanupStop)
        if !r.ambiguous, r.converterStatus == noErr, let converter = r.converter {
            if session.close({ AudioConverterDispose(converter) }) { r.converter = nil } else { r.ambiguous = true }
        }
        if !r.ambiguous, r.fileStatus == noErr, let file = r.file {
            if session.close({ AudioFileClose(file) }) { r.file = nil } else { r.ambiguous = true }
        }
        guard !r.ambiguous, session.cleanupHealthy else { throw NativeAACM4AError.nativeFailure }
        if let failure { r.owner = nil; r.feed = nil; throw failure }
        guard let duration, r.owner!.healthy(), r.feed!.complete(expected: input.pcm) else { throw NativeAACM4AError.nativeFailure }
        let encoded = r.owner!.bytes()
        r.owner = nil; r.feed = nil
        guard weakOwner == nil, weakFeed == nil, ownerLife.value() == 1, feedLife.value() == 1 else { throw NativeAACM4AError.nativeFailure }
        try verifyClosed(encoded, input: input, duration: duration, packetFrames: queriedPacketFrames,
                         packets: packets, session: session, retaining: r)
        return (encoded, duration)
    }
    private static func sameTable(_ table: AudioFilePacketTableInfo, measured: AACM4AProtocol.Duration, frames: Int) -> Bool {
        table.mNumberValidFrames == Int64(frames) && table.mPrimingFrames == Int32(measured.leading)
            && table.mRemainderFrames == Int32(measured.trailing)
    }
    private static func verifyClosed(_ bytes: Data, input: AACM4AProtocol.Input, duration: AACM4AProtocol.Duration,
                                     packetFrames: UInt32, packets: Int, session: AACSession, retaining r: AACChildRetentions) throws {
        guard !bytes.isEmpty, bytes.count <= encodedCap else { throw NativePCM16WAVError.outputLimit }
        let life = Lifetime()
        r.reader = CallbackFile(bytes: bytes, life: life, workStop: session.workStop)
        weak var weakReader = r.reader
        var failure: Error?
        do {
            _ = try session.call {
                r.readStatus = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(r.reader!).toOpaque(),
                    readProc, nil, sizeProc, nil, kAudioFileM4AType, &r.readFile)
                return r.readStatus!
            }
            guard r.readStatus == noErr, let file = r.readFile else { throw NativeAACM4AError.nativeFailure }
            let type: UInt32 = try session.fileProperty(file, kAudioFilePropertyFileFormat, initial: UInt32(0))
            let a = try session.fileProperty(file, kAudioFilePropertyDataFormat, initial: AudioStreamBasicDescription())
            let count: UInt64 = try session.fileProperty(file, kAudioFilePropertyAudioDataPacketCount, initial: UInt64(0))
            let table = try session.fileProperty(file, kAudioFilePropertyPacketTableInfo, initial: AudioFilePacketTableInfo())
            guard type == kAudioFileM4AType, a.mFormatID == kAudioFormatMPEG4AAC, a.mSampleRate == Double(input.rate),
                  a.mChannelsPerFrame == UInt32(input.channels), a.mFramesPerPacket == packetFrames,
                  count == UInt64(packets), sameTable(table, measured: duration, frames: input.frames), r.reader!.healthy() else {
                throw NativeAACM4AError.nativeFailure
            }
        } catch { failure = error }
        r.ambiguous = (r.readStatus == noErr && r.readFile == nil)
            || (r.readStatus != nil && r.readStatus != noErr && r.readFile != nil)
        r.reader?.beginCleanup(until: session.cleanupStop)
        if !r.ambiguous, r.readStatus == noErr, let file = r.readFile {
            if session.close({ AudioFileClose(file) }) { r.readFile = nil } else { r.ambiguous = true }
        }
        guard !r.ambiguous, session.cleanupHealthy else { throw NativeAACM4AError.nativeFailure }
        let healthy = r.reader?.healthy() == true
        r.reader = nil
        guard healthy, weakReader == nil, life.value() == 1 else { throw NativeAACM4AError.nativeFailure }
        if let failure { throw failure }
        try session.healthy()
    }
}

/// This mode exits only its admitted headless child, before application bootstrap.
public enum AACM4AChildEntry {
    @discardableResult
    public static func runIfRequested(arguments: [String] = CommandLine.arguments,
                                      expectedRole: WebRenderProductRole) -> Bool {
        guard arguments.dropFirst().first == OwnedCurrentSelfMode.aacM4AV1.argument else { return false }
        guard arguments.count == 2, Thread.isMainThread else { _exit(2) }
        let end = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        // Scoped to this fixed child mode, never installed by ForgeApp.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { _exit(124) }
        DispatchQueue.global(qos: .userInitiated).async {
            let retained = AACChildRetentions()
            withExtendedLifetime(retained) {
                do {
                    _ = try OwnedCurrentSelfAdmission.current(expectedRole: expectedRole == .app ? .app : .cli)
                    let raw = try readInput(end: min(end, DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
                    let input = try AACM4AProtocol.decodeRequest(raw)
                    let (encoded, duration) = try AACChildCodec.encode(input, end: end, retaining: retained)
                    let reply = try AACM4AProtocol.reply(input: input, encoded: encoded, duration: duration)
                    try writeOutput(reply, end: end)
                    guard Darwin.close(STDOUT_FILENO) == 0, Darwin.close(STDERR_FILENO) == 0 else { _exit(2) }
                    _exit(0)
                } catch { _exit(2) }
            }
        }
        dispatchMain()
    }
    private static func nonblocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw NativeAACM4AError.transport }
    }
    private static func readInput(end: UInt64) throws -> Data {
        try nonblocking(STDIN_FILENO)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while DispatchTime.now().uptimeNanoseconds < end {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress,
                min($0.count, AACM4AProtocol.maximumRequestBytes + 1 - data.count)) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= AACM4AProtocol.maximumRequestBytes else { throw NativeAACM4AError.transport }
            } else if count == 0 { return data }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0); _ = Darwin.poll(&p, 1, 20)
            } else { throw NativeAACM4AError.transport }
        }
        throw ToolCallDeadlineExceeded()
    }
    private static func writeOutput(_ data: Data, end: UInt64) throws {
        try nonblocking(STDOUT_FILENO)
        guard data.count <= AACM4AProtocol.maximumReplyBytes, Darwin.fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { throw NativeAACM4AError.transport }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < end else { throw ToolCallDeadlineExceeded() }
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), min(8_192, bytes.count - offset))
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var p = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0); _ = Darwin.poll(&p, 1, 20)
                } else { throw NativeAACM4AError.transport }
            }
        }
    }
}

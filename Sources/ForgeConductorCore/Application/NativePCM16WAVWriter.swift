import Foundation

enum NativePCM16WAVError: Error, Equatable, LocalizedError {
    case workerRequired, invalidSampleRate, invalidChannels, invalidContent
    case inputLimit, incompleteFrames, outputLimit, internalMismatch

    var code: String {
        switch self {
        case .workerRequired: "audio_worker_required"
        case .invalidSampleRate: "invalid_audio_sample_rate"
        case .invalidChannels: "invalid_audio_channels"
        case .invalidContent: "invalid_audio_content"
        case .inputLimit: "audio_input_too_large"
        case .incompleteFrames: "invalid_audio_frames"
        case .outputLimit: "audio_output_too_large"
        case .internalMismatch: "audio_encode_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "WAV encoding requires a worker thread"
        case .invalidSampleRate: "sample_rate must be an integer equal to 8000, 44100 or 48000"
        case .invalidChannels: "channels must be the integer 1 or 2"
        case .invalidContent: "content must be nonempty canonical padded base64 of signed PCM16 little-endian bytes"
        case .inputLimit: "PCM input is limited to 1048576 decoded bytes and 1398104 base64 UTF-8 bytes"
        case .incompleteFrames: "PCM content must contain at least one complete frame of channels * 2 bytes"
        case .outputLimit: "Complete WAV output exceeds the bounded output limit"
        case .internalMismatch: "WAV encoding could not confirm the preflight plan"
        }
    }
}

/// One call-local PCM RIFF serializer. It reads no file and creates no audio handle.
enum NativePCM16WAVWriter {
    static let sampleRates: Set<Int> = [8_000, 44_100, 48_000]
    static let maximumInputBytes = 1_048_576
    static let maximumBase64Bytes = ((maximumInputBytes + 2) / 3) * 4
    static let maximumOutputBytes = 2_097_152
    static let inputContract = "pcm16le-interleaved-v1"
    static let outputContract = "wav-pcm16le-interleaved-v1"

    struct EncodedAudio {
        let data: Data
        let sampleRate: Int
        let channels: Int
        let frames: Int
        let pcmBytes: Int
    }

    static func sampleRate(_ value: Any?) throws -> Int {
        guard let rate = JSONSupport.exactInteger(value), sampleRates.contains(rate) else {
            throw NativePCM16WAVError.invalidSampleRate
        }
        return rate
    }

    static func channels(_ value: Any?) throws -> Int {
        guard let count = JSONSupport.exactInteger(value), count == 1 || count == 2 else {
            throw NativePCM16WAVError.invalidChannels
        }
        return count
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

    private struct Output {
        let limit: Int
        var data: Data
        init(limit: Int) { self.limit = limit; data = Data(capacity: limit) }

        mutating func bytes(_ bytes: [UInt8], cancellation: ToolCallCancellation?) throws {
            try cancellation?.checkCancellation()
            guard bytes.count <= limit - data.count else { throw NativePCM16WAVError.outputLimit }
            data.append(contentsOf: bytes)
        }

        mutating func little16(_ value: UInt16, cancellation: ToolCallCancellation?) throws {
            try bytes([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)], cancellation: cancellation)
        }

        mutating func little32(_ value: UInt32, cancellation: ToolCallCancellation?) throws {
            try bytes([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                       UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)], cancellation: cancellation)
        }

        mutating func pcm(_ raw: Data, cancellation: ToolCallCancellation?) throws {
            guard raw.count <= limit - data.count else { throw NativePCM16WAVError.outputLimit }
            var offset = 0
            while offset < raw.count {
                try cancellation?.checkCancellation()
                let end = offset + min(4096, raw.count - offset)
                data.append(raw[offset..<end]); offset = end
            }
        }
    }

    static func encode(content: String, sampleRate: Int, channels: Int,
                       cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> EncodedAudio {
        guard !Thread.isMainThread else { throw NativePCM16WAVError.workerRequired }
        try cancellation?.checkCancellation()
        guard sampleRates.contains(sampleRate) else { throw NativePCM16WAVError.invalidSampleRate }
        guard channels == 1 || channels == 2 else { throw NativePCM16WAVError.invalidChannels }
        let rawCount = try rawSize(content, cancellation: cancellation)
        let blockAlign = channels * 2
        guard rawCount % blockAlign == 0 else { throw NativePCM16WAVError.incompleteFrames }
        let frames = rawCount / blockAlign
        guard frames > 0 else { throw NativePCM16WAVError.incompleteFrames }
        let total = 44 + rawCount
        guard (1...maximumOutputBytes).contains(outputByteLimit), total <= outputByteLimit else {
            throw NativePCM16WAVError.outputLimit
        }
        let byteRate = sampleRate * blockAlign
        // Rate, channel count, raw size and every header field are bounded before allocation.
        try cancellation?.checkCancellation()
        guard let raw = Data(base64Encoded: content), raw.count == rawCount,
              raw.base64EncodedString() == content else { throw NativePCM16WAVError.internalMismatch }
        try cancellation?.checkCancellation()
        var output = Output(limit: total)
        try output.bytes([0x52, 0x49, 0x46, 0x46], cancellation: cancellation)
        try output.little32(UInt32(total - 8), cancellation: cancellation)
        try output.bytes([0x57, 0x41, 0x56, 0x45], cancellation: cancellation)
        try output.bytes([0x66, 0x6D, 0x74, 0x20], cancellation: cancellation)
        try output.little32(16, cancellation: cancellation)
        try output.little16(1, cancellation: cancellation)
        try output.little16(UInt16(channels), cancellation: cancellation)
        try output.little32(UInt32(sampleRate), cancellation: cancellation)
        try output.little32(UInt32(byteRate), cancellation: cancellation)
        try output.little16(UInt16(blockAlign), cancellation: cancellation)
        try output.little16(16, cancellation: cancellation)
        try output.bytes([0x64, 0x61, 0x74, 0x61], cancellation: cancellation)
        try output.little32(UInt32(rawCount), cancellation: cancellation)
        try output.pcm(raw, cancellation: cancellation)
        try cancellation?.checkCancellation()
        guard output.data.count == total else { throw NativePCM16WAVError.internalMismatch }
        return EncodedAudio(data: output.data, sampleRate: sampleRate, channels: channels,
                            frames: frames, pcmBytes: rawCount)
    }
}

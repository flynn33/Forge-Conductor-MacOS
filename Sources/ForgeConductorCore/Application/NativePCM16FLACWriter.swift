import Foundation
import CryptoKit

/// Call-local PCM16 FLAC serializer with independent verbatim channel subframes.
enum NativePCM16FLACWriter {
    static let sampleRates: Set<Int> = [8_000, 44_100, 48_000]
    static let maximumInputBytes = 1_048_576
    static let maximumBase64Bytes = ((maximumInputBytes + 2) / 3) * 4
    static let maximumOutputBytes = 2_097_152
    static let nominalBlockFrames = 4_608
    static let inputContract = "pcm16le-interleaved-v1"
    static let outputContract = "flac-pcm16le-verbatim-v1"

    typealias EncodedAudio = NativePCM16WAVWriter.EncodedAudio

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

    private static func crc8(_ value: UInt8, byte: UInt8) -> UInt8 {
        var crc = value ^ byte
        for _ in 0..<8 { crc = crc & 0x80 == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x07 }
        return crc
    }
    private static func crc16(_ value: UInt16, byte: UInt8) -> UInt16 {
        var crc = value ^ (UInt16(byte) << 8)
        for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x8005 }
        return crc
    }

    private struct Output {
        let limit: Int
        var data: Data
        private var frameCRC: UInt16 = 0
        private var inFrame = false
        init(limit: Int) { self.limit = limit; data = Data(capacity: limit) }
        mutating func byte(_ byte: UInt8) throws {
            guard data.count < limit else { throw NativePCM16WAVError.outputLimit }
            data.append(byte)
            if inFrame { frameCRC = NativePCM16FLACWriter.crc16(frameCRC, byte: byte) }
        }
        mutating func big16(_ value: UInt16) throws {
            try byte(UInt8(truncatingIfNeeded: value >> 8)); try byte(UInt8(truncatingIfNeeded: value))
        }
        mutating func big24(_ value: Int) throws {
            try byte(UInt8(truncatingIfNeeded: value >> 16)); try byte(UInt8(truncatingIfNeeded: value >> 8)); try byte(UInt8(truncatingIfNeeded: value))
        }
        mutating func big64(_ value: UInt64) throws {
            for shift in stride(from: 56, through: 0, by: -8) { try byte(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        mutating func frameHeader(rateCode: UInt8, channels: Int, index: Int, count: Int) throws {
            frameCRC = 0; inFrame = true
            let header: [UInt8] = [0xFF, 0xF8, 0x70 | rateCode, UInt8((channels - 1) << 4) | 0x08,
                UInt8(index), UInt8(truncatingIfNeeded: (count - 1) >> 8), UInt8(truncatingIfNeeded: count - 1)]
            var headerCRC: UInt8 = 0
            for byte in header { headerCRC = NativePCM16FLACWriter.crc8(headerCRC, byte: byte); try self.byte(byte) }
            try byte(headerCRC)
        }
        mutating func endFrame() throws {
            let footer = frameCRC; inFrame = false; try big16(footer)
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
        let blockCount = (frames + nominalBlockFrames - 1) / nominalBlockFrames
        let total = 42 + rawCount + blockCount * (10 + channels)
        guard (1...maximumOutputBytes).contains(outputByteLimit), total <= outputByteLimit else {
            throw NativePCM16WAVError.outputLimit
        }
        let lastCount = frames - (blockCount - 1) * nominalBlockFrames
        let minimumFrameBytes = lastCount * blockAlign + 10 + channels
        let maximumFrameBytes = min(frames, nominalBlockFrames) * blockAlign + 10 + channels
        guard blockCount <= 114, blockCount > 0, (1...nominalBlockFrames).contains(lastCount),
              maximumFrameBytes <= 18_444, minimumFrameBytes > 0,
              frames <= 524_288 else { throw NativePCM16WAVError.internalMismatch }
        try cancellation?.checkCancellation()
        guard let raw = Data(base64Encoded: content), raw.count == rawCount,
              raw.base64EncodedString() == content else { throw NativePCM16WAVError.internalMismatch }
        try cancellation?.checkCancellation()
        var checksum = Insecure.MD5()
        try raw.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw NativePCM16WAVError.internalMismatch }
            var offset = 0
            while offset < raw.count {
                try cancellation?.checkCancellation()
                let count = min(4096, raw.count - offset)
                checksum.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: offset), count: count))
                offset += count
            }
        }
        try cancellation?.checkCancellation()
        var output = Output(limit: total)
        let prefix: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x80, 0, 0, 0x22]
        for byte in prefix { try output.byte(byte) }
        try output.big16(UInt16(nominalBlockFrames)); try output.big16(UInt16(nominalBlockFrames))
        try output.big24(minimumFrameBytes); try output.big24(maximumFrameBytes)
        let streamBits = (UInt64(sampleRate) << 44) | (UInt64(channels - 1) << 41) | (UInt64(15) << 36) | UInt64(frames)
        try output.big64(streamBits)
        for byte in checksum.finalize() { try output.byte(byte) }
        guard output.data.count == 42 else { throw NativePCM16WAVError.internalMismatch }
        let rateCode: UInt8 = sampleRate == 8000 ? 4 : sampleRate == 44100 ? 9 : 10
        try raw.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            var start = 0
            for index in 0..<blockCount {
                try cancellation?.checkCancellation()
                let count = min(nominalBlockFrames, frames - start)
                try output.frameHeader(rateCode: rateCode, channels: channels, index: index, count: count)
                for channel in 0..<channels {
                    try output.byte(0x02)
                    for sample in 0..<count {
                        if sample % 1024 == 0 { try cancellation?.checkCancellation() }
                        let offset = ((start + sample) * channels + channel) * 2
                        try output.byte(input[offset + 1]); try output.byte(input[offset])
                    }
                }
                try output.endFrame(); start += count
            }
            guard start == frames else { throw NativePCM16WAVError.internalMismatch }
        }
        try cancellation?.checkCancellation()
        guard output.data.count == total else { throw NativePCM16WAVError.internalMismatch }
        return EncodedAudio(data: output.data, sampleRate: sampleRate, channels: channels,
                            frames: frames, pcmBytes: rawCount)
    }
}

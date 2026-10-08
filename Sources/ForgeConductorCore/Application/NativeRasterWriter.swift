import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum NativeRasterError: Error, Equatable, LocalizedError {
    case workerRequired, invalidDimensions, invalidContent, invalidPixelFormat, invalidFormat
    case invalidAlpha, outputTooLarge, encoderUnavailable

    var code: String {
        switch self {
        case .workerRequired: "image_worker_required"
        case .invalidDimensions: "invalid_image_dimensions"
        case .invalidContent: "invalid_content"
        case .invalidPixelFormat: "invalid_pixel_format"
        case .invalidFormat: "invalid_image_format"
        case .invalidAlpha: "invalid_image_alpha"
        case .outputTooLarge: "image_output_too_large"
        case .encoderUnavailable: "image_encoder_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "Image encoding requires a worker thread"
        case .invalidDimensions: "width and height must be integers from 1 through 1024, with at most 262144 pixels"
        case .invalidContent: "content must be canonical padded base64 containing exactly width × height × 4 RGBA8 bytes, at most 1048576 bytes"
        case .invalidPixelFormat: "pixel_format must be rgba8"
        case .invalidFormat: "format must be png, tiff or jpeg"
        case .invalidAlpha: "JPEG requires every RGBA8 alpha byte to be 255; use png or tiff for transparency"
        case .outputTooLarge: "Encoded image is limited to 2097152 bytes"
        case .encoderUnavailable: "The native image encoder could not complete the image"
        }
    }
}

/// Call-local PNG/TIFF and opaque lossy JPEG encoding of sRGB RGBA8 pixels.
enum NativeRasterWriter {
    static let maximumDimension = 1024
    static let maximumPixels = 262_144
    static let maximumInputBytes = maximumPixels * 4
    static let maximumBase64Bytes = ((maximumInputBytes + 2) / 3) * 4
    static let maximumOutputBytes = 2_097_152
    static let pixelContract = "rgba8-straight-srgb-v1"
    static let jpegOutputContract = "jpeg-opaque-lossy-srgb-v1"

    static func integerDimension(_ value: Any?) throws -> Int {
        guard let dimension = JSONSupport.exactInteger(value), (1...maximumDimension).contains(dimension) else {
            throw NativeRasterError.invalidDimensions
        }
        return dimension
    }

    static func encode(width: Int, height: Int, content: String,
                       pixelFormat: String = "rgba8", format: String = "png",
                       cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = maximumOutputBytes) throws -> Data {
        guard !Thread.isMainThread else { throw NativeRasterError.workerRequired }
        try cancellation?.checkCancellation()
        guard format == "png" || format == "tiff" || format == "jpeg" else { throw NativeRasterError.invalidFormat }
        guard pixelFormat == "rgba8" else { throw NativeRasterError.invalidPixelFormat }
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw NativeRasterError.invalidDimensions
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else { throw NativeRasterError.invalidDimensions }
        let expectedBytes = pixels * 4
        guard content.utf8.prefix(maximumBase64Bytes + 1).count <= maximumBase64Bytes,
              content.utf8.count == ((expectedBytes + 2) / 3) * 4,
              let raw = Data(base64Encoded: content), raw.count == expectedBytes,
              raw.base64EncodedString() == content else { throw NativeRasterError.invalidContent }
        try cancellation?.checkCancellation()
        guard outputByteLimit > 0, outputByteLimit <= maximumOutputBytes else {
            throw NativeRasterError.outputTooLarge
        }
        if format == "tiff" {
            return try encodeTIFF(raw, width: width, height: height, cancellation: cancellation, outputByteLimit: outputByteLimit)
        }
        if format == "jpeg" {
            try raw.withUnsafeBytes { bytes in
                for offset in stride(from: 3, to: bytes.count, by: 4) {
                    if offset % 8192 == 3 { try cancellation?.checkCancellation() }
                    guard bytes[offset] == 255 else { throw NativeRasterError.invalidAlpha }
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NativeRasterError.encoderUnavailable
        }
        let output = Output(maximumBytes: outputByteLimit, cancellation: cancellation)
        let retainedOutput = Unmanaged.passRetained(output)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { information, bytes, count in
                guard let information else { return 0 }
                return Unmanaged<Output>.fromOpaque(information).takeUnretainedValue().append(bytes, count: count)
            },
            releaseConsumer: { information in
                if let information { Unmanaged<Output>.fromOpaque(information).release() }
            }
        )
        guard let consumer = CGDataConsumer(info: retainedOutput.toOpaque(), cbks: &callbacks) else {
            retainedOutput.release()
            throw NativeRasterError.encoderUnavailable
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(
            consumer, (format == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil
        ) else { throw NativeRasterError.encoderUnavailable }
        let properties: CFDictionary? = format == "jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImageDestinationEmbedThumbnail: false] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        try output.check()
        let finalized = CGImageDestinationFinalize(destination)
        let encoded = try withExtendedLifetime((raw, provider, image, consumer, destination)) { try output.snapshot() }
        guard finalized, !encoded.isEmpty else { throw NativeRasterError.encoderUnavailable }
        return encoded
    }

    private static func encodeTIFF(_ raw: Data, width: Int, height: Int,
                                   cancellation: ToolCallCancellation?, outputByteLimit: Int) throws -> Data {
        try cancellation?.checkCancellation()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let profileData = space.copyICCData() else { throw NativeRasterError.encoderUnavailable }
        let profile = profileData as Data
        guard profile.count >= 128, profile.count <= 65_536 else { throw NativeRasterError.encoderUnavailable }
        let rowBytes = width * 4
        let rowsPerStrip = min(height, 65_536 / rowBytes)
        let stripCount = (height + rowsPerStrip - 1) / rowsPerStrip
        let bitsOffset = 8 + 2 + 16 * 12 + 4
        let xResolutionOffset = bitsOffset + 8
        let yResolutionOffset = xResolutionOffset + 8
        let offsetsOffset = yResolutionOffset + 8
        let countsOffset = offsetsOffset + (stripCount > 1 ? stripCount * 4 : 0)
        let profileOffset = countsOffset + (stripCount > 1 ? stripCount * 4 : 0)
        let pixelsOffset = profileOffset + profile.count + profile.count % 2
        guard pixelsOffset + raw.count <= outputByteLimit else { throw NativeRasterError.outputTooLarge }
        let output = Output(maximumBytes: outputByteLimit, cancellation: cancellation)
        func short(_ value: UInt16) throws {
            try output.append(Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]))
        }
        func word(_ value: UInt32) throws {
            try output.append(Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }))
        }
        func field(_ tag: UInt16, _ type: UInt16, _ count: Int, _ value: Int) throws {
            try short(tag); try short(type); try word(UInt32(count)); try word(UInt32(value))
        }
        func stripBytes(_ index: Int) -> Int { rowBytes * min(rowsPerStrip, height - index * rowsPerStrip) }
        // TIFF 6.0 sorted IFD; ICC embedding uses tag 34675, type UNDEFINED.
        try output.append(Data([73, 73])); try short(42); try word(8); try short(16)
        try field(256, 4, 1, width); try field(257, 4, 1, height)
        try field(258, 3, 4, bitsOffset); try field(259, 3, 1, 1); try field(262, 3, 1, 2)
        try field(273, 4, stripCount, stripCount == 1 ? pixelsOffset : offsetsOffset)
        try field(274, 3, 1, 1); try field(277, 3, 1, 4); try field(278, 4, 1, rowsPerStrip)
        try field(279, 4, stripCount, stripCount == 1 ? raw.count : countsOffset)
        try field(282, 5, 1, xResolutionOffset); try field(283, 5, 1, yResolutionOffset)
        try field(284, 3, 1, 1); try field(296, 3, 1, 2); try field(338, 3, 1, 2)
        try field(34675, 7, profile.count, profileOffset); try word(0)
        for _ in 0..<4 { try short(8) }
        for _ in 0..<2 { try word(72); try word(1) }
        if stripCount > 1 {
            for index in 0..<stripCount { try word(UInt32(pixelsOffset + index * rowsPerStrip * rowBytes)) }
            for index in 0..<stripCount { try word(UInt32(stripBytes(index))) }
        }
        try output.append(profile)
        if profile.count % 2 == 1 { try output.append(Data([0])) }
        try raw.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw NativeRasterError.invalidContent }
            for offset in stride(from: 0, to: raw.count, by: 8192) {
                _ = output.append(base.advanced(by: offset), count: min(8192, raw.count - offset))
                try output.check()
            }
        }
        return try output.snapshot()
    }

    private final class Output {
        private let lock = NSLock()
        private var data = Data()
        private var error: Error?
        private let maximumBytes: Int
        private let cancellation: ToolCallCancellation?

        init(maximumBytes: Int, cancellation: ToolCallCancellation?) {
            self.maximumBytes = maximumBytes
            self.cancellation = cancellation
        }

        func check() throws {
            lock.lock(); defer { lock.unlock() }
            try checkLocked()
        }

        private func checkLocked() throws {
            if let error { throw error }
            do { try cancellation?.checkCancellation() }
            catch { self.error = error; throw error }
        }

        func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            do {
                try checkLocked()
                guard count >= 0, count <= maximumBytes - data.count else { throw NativeRasterError.outputTooLarge }
                data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
                return count
            } catch let caught {
                if error == nil { error = caught }
                return 0
            }
        }

        func append(_ bytes: Data) throws {
            bytes.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress { _ = append(base, count: buffer.count) }
            }
            try check()
        }

        func snapshot() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            try checkLocked()
            return data
        }
    }
}

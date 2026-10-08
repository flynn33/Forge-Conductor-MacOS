import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum NativeRasterError: Error, Equatable, LocalizedError {
    case workerRequired, invalidDimensions, invalidContent, invalidPixelFormat, invalidFormat
    case outputTooLarge, encoderUnavailable

    var code: String {
        switch self {
        case .workerRequired: "image_worker_required"
        case .invalidDimensions: "invalid_image_dimensions"
        case .invalidContent: "invalid_content"
        case .invalidPixelFormat: "invalid_pixel_format"
        case .invalidFormat: "invalid_image_format"
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
        case .invalidFormat: "format must be png"
        case .outputTooLarge: "Encoded PNG is limited to 2097152 bytes"
        case .encoderUnavailable: "The native PNG encoder could not complete the image"
        }
    }
}

/// Call-local ImageIO encoding of straight-alpha sRGB RGBA8 pixels.
enum NativeRasterWriter {
    static let maximumDimension = 1024
    static let maximumPixels = 262_144
    static let maximumInputBytes = maximumPixels * 4
    static let maximumBase64Bytes = ((maximumInputBytes + 2) / 3) * 4
    static let maximumOutputBytes = 2_097_152
    static let pixelContract = "rgba8-straight-srgb-v1"

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
        guard format == "png" else { throw NativeRasterError.invalidFormat }
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
            consumer, UTType.png.identifier as CFString, 1, nil
        ) else { throw NativeRasterError.encoderUnavailable }
        CGImageDestinationAddImage(destination, image, nil)
        try output.check()
        let finalized = CGImageDestinationFinalize(destination)
        let encoded = try withExtendedLifetime((raw, provider, image, consumer, destination)) { try output.snapshot() }
        guard finalized, !encoded.isEmpty else { throw NativeRasterError.encoderUnavailable }
        return encoded
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

        func snapshot() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            try checkLocked()
            return data
        }
    }
}

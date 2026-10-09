import Foundation
import Darwin
import zlib

enum NativeGZIPArchiveError: Error, Equatable, LocalizedError {
    case nativeFailure, allocationFailure, cleanupFailure
    var code: String { "archive_encode_failed" }
    var errorDescription: String? {
        switch self {
        case .nativeFailure: "System GZIP encoding could not confirm a complete bounded stream"
        case .allocationFailure: "System GZIP state exceeded its bounded allocation policy"
        case .cleanupFailure: "System GZIP stream cleanup could not be confirmed"
        }
    }
}

/// One call-local system-zlib GZIP member containing the complete bounded PAX TAR.
enum NativeGZIPArchiveWriter {
    static let outputContract = "tar-gzip-pax-supplied-files-v1"
    static let maximumStateBytes = 1_048_576
    static let maximumAllocations = 32
    private static let chunkBytes = 65_536

    struct Compressed {
        let data: Data
        let allocationCount: Int
        let freeCount: Int
        let peakStateBytes: Int
        let endStatus: Int32
    }

    /// The callbacks have no Swift throws; the owner outlives deflateEnd on every path.
    private final class Allocations {
        private let lock = NSLock()
        private let limit: Int
        private var blocks: [(UnsafeMutableRawPointer, Int)] = []
        private(set) var allocations = 0
        private(set) var frees = 0
        private(set) var peak = 0
        private var bytes = 0
        private var attempts = 0
        private var invalidFree = false
        init(limit: Int) { self.limit = limit }
        func allocate(items: UInt32, size: UInt32) -> UnsafeMutableRawPointer? {
            lock.lock(); defer { lock.unlock() }
            guard attempts < 8_192 else { return nil }
            attempts += 1
            let (count, overflow) = Int(items).multipliedReportingOverflow(by: Int(size))
            guard !overflow, count > 0, blocks.count < maximumAllocations,
                  count <= limit - bytes, let pointer = malloc(count) else { return nil }
            blocks.append((pointer, count)); bytes += count; allocations += 1; peak = max(peak, bytes)
            return pointer
        }
        func release(_ pointer: UnsafeMutableRawPointer?) {
            guard let pointer else { return }
            lock.lock(); defer { lock.unlock() }
            guard let index = blocks.firstIndex(where: { $0.0 == pointer }) else { invalidFree = true; return }
            let block = blocks.remove(at: index); bytes -= block.1; frees += 1; free(pointer)
        }
        var released: Bool {
            lock.lock(); defer { lock.unlock() }
            return blocks.isEmpty && bytes == 0 && !invalidFree && allocations == frees
        }
    }

    static func compress(_ tar: Data, cancellation: ToolCallCancellation? = nil,
                         outputByteLimit: Int = NativePAXTARWriter.maximumOutputBytes,
                         stateByteLimit: Int = maximumStateBytes) throws -> Compressed {
        guard !Thread.isMainThread else { throw NativePAXTARError.admission(.workerRequired) }
        try cancellation?.checkCancellation()
        guard (1...NativePAXTARWriter.maximumOutputBytes).contains(outputByteLimit),
              (1...maximumStateBytes).contains(stateByteLimit),
              (1_024...NativePAXTARWriter.maximumOutputBytes).contains(tar.count) else {
            throw NativePAXTARError.admission(.outputLimit)
        }
        let owner = Allocations(limit: stateByteLimit)
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let header = UnsafeMutablePointer<gz_header>.allocate(capacity: 1)
        header.initialize(to: gz_header()); header.pointee.os = 255
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkBytes)
        defer {
            buffer.deallocate(); header.deinitialize(count: 1); header.deallocate()
            stream.deinitialize(count: 1); stream.deallocate()
        }
        stream.pointee.opaque = Unmanaged.passUnretained(owner).toOpaque()
        stream.pointee.zalloc = { opaque, items, size in
            guard let opaque else { return nil }
            return Unmanaged<Allocations>.fromOpaque(opaque).takeUnretainedValue().allocate(items: items, size: size)
        }
        stream.pointee.zfree = { opaque, pointer in
            guard let opaque else { return }
            Unmanaged<Allocations>.fromOpaque(opaque).takeUnretainedValue().release(pointer)
        }
        let initialized = deflateInit2_(stream, 5, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                        ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else {
            // No success-created stream exists. Unknown remaining blocks are never freed by hand.
            guard owner.released else { throw NativeGZIPArchiveError.cleanupFailure }
            throw initialized == Z_MEM_ERROR ? NativeGZIPArchiveError.allocationFailure : NativeGZIPArchiveError.nativeFailure
        }
        var failure: Error?
        var output = Data()
        var finished = false
        do {
            try cancellation?.checkCancellation()
            guard deflateSetHeader(stream, header) == Z_OK else { throw NativeGZIPArchiveError.nativeFailure }
            try cancellation?.checkCancellation()
            let bound = deflateBound(stream, uLong(tar.count))
            guard bound > 0, bound <= uLong(NativePAXTARWriter.maximumOutputBytes) else {
                throw NativePAXTARError.admission(.outputLimit)
            }
            output.reserveCapacity(min(outputByteLimit, Int(bound)))
            try tar.withUnsafeBytes { raw in
                guard let input = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw NativeGZIPArchiveError.nativeFailure
                }
                defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                var supplied = 0, calls = 0
                while !finished {
                    try cancellation?.checkCancellation()
                    guard calls < 4_096 else { throw NativeGZIPArchiveError.nativeFailure }
                    if stream.pointee.avail_in == 0 && supplied < tar.count {
                        let count = min(chunkBytes, tar.count - supplied)
                        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.advanced(by: supplied))
                        stream.pointee.avail_in = uInt(count); supplied += count
                    }
                    let capacity = min(chunkBytes, outputByteLimit - output.count)
                    guard capacity > 0 else { throw NativePAXTARError.admission(.outputLimit) }
                    stream.pointee.next_out = buffer; stream.pointee.avail_out = uInt(capacity)
                    let oldInput = stream.pointee.total_in
                    let status = deflate(stream, supplied == tar.count ? Z_FINISH : Z_NO_FLUSH)
                    calls += 1
                    try cancellation?.checkCancellation()
                    guard stream.pointee.avail_out <= uInt(capacity), stream.pointee.total_in <= uLong(tar.count) else {
                        throw NativeGZIPArchiveError.nativeFailure
                    }
                    let produced = capacity - Int(stream.pointee.avail_out)
                    guard produced <= outputByteLimit - output.count else { throw NativePAXTARError.admission(.outputLimit) }
                    output.append(buffer, count: produced)
                    if status == Z_STREAM_END {
                        guard stream.pointee.avail_in == 0, stream.pointee.total_in == uLong(tar.count),
                              supplied == tar.count else { throw NativeGZIPArchiveError.nativeFailure }
                        finished = true
                    } else {
                        guard status == Z_OK, produced > 0 || stream.pointee.total_in > oldInput else {
                            throw NativeGZIPArchiveError.nativeFailure
                        }
                    }
                }
            }
            try cancellation?.checkCancellation()
            guard finished, output.count >= 18 else { throw NativeGZIPArchiveError.nativeFailure }
        } catch { failure = error }
        // End also frees a prematurely discarded stream; Z_DATA_ERROR never makes that encode pass.
        let ended = withExtendedLifetime(owner) { deflateEnd(stream) }
        guard owner.released else { throw NativeGZIPArchiveError.cleanupFailure }
        if let failure { throw failure }
        guard ended == Z_OK, finished else { throw NativeGZIPArchiveError.cleanupFailure }
        try cancellation?.checkCancellation()
        return Compressed(data: output, allocationCount: owner.allocations, freeCount: owner.frees,
                          peakStateBytes: owner.peak, endStatus: ended)
    }

    static func encode(entries: Any?, cancellation: ToolCallCancellation? = nil,
                       outputByteLimit: Int = NativePAXTARWriter.maximumOutputBytes) throws -> NativeStoredZIPWriter.EncodedArchive {
        guard !Thread.isMainThread else { throw NativePAXTARError.admission(.workerRequired) }
        try cancellation?.checkCancellation()
        guard (1...NativePAXTARWriter.maximumOutputBytes).contains(outputByteLimit) else {
            throw NativePAXTARError.admission(.outputLimit)
        }
        let tar = try NativePAXTARWriter.encode(entries: entries, cancellation: cancellation)
        let gzip = try compress(tar.data, cancellation: cancellation, outputByteLimit: outputByteLimit)
        return NativeStoredZIPWriter.EncodedArchive(data: gzip.data, entryCount: tar.entryCount, inputBytes: tar.inputBytes)
    }
}

import Foundation
import Compression

/// Small, dependency-free data compression helper for storing tracks efficiently.
///
/// Uses ZLIB so the data remains portable and fast on Apple platforms.
enum JourneyCompression {
    enum Error: Swift.Error { case encodeFailed, decodeFailed }

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        return try data.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw Error.encodeFailed
            }

            // ZLIB may expand slightly; start with 2x and shrink after.
            let dstCapacity = max(64, data.count * 2)
            var dst = Data(count: dstCapacity)

            let outCount = dst.withUnsafeMutableBytes { dstRaw -> Int in
                guard let d = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(d, dstCapacity, src, data.count, nil, COMPRESSION_ZLIB)
            }

            guard outCount > 0 else { throw Error.encodeFailed }
            dst.removeSubrange(outCount..<dst.count)
            return dst
        }
    }

    static func decompress(_ data: Data, hint: Int = 64 * 1024) throws -> Data {
        guard !data.isEmpty else { return data }

        return try data.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw Error.decodeFailed
            }

            var dstCapacity = max(hint, data.count * 4)

            // Try a few times, expanding the buffer if needed.
            for _ in 0..<8 {
                var dst = Data(count: dstCapacity)
                let outCount = dst.withUnsafeMutableBytes { dstRaw -> Int in
                    guard let d = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    return compression_decode_buffer(d, dstCapacity, src, data.count, nil, COMPRESSION_ZLIB)
                }

                if outCount > 0 {
                    dst.removeSubrange(outCount..<dst.count)
                    return dst
                }
                dstCapacity *= 2
            }

            throw Error.decodeFailed
        }
    }
}

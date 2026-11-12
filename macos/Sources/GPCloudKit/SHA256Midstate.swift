import Foundation

/// Streaming SHA-256 that exposes its internal state ("midstate").
///
/// GP Cloud's multipart upload (a wrapper around Huawei Drive Kit) requires, for every
/// slice, the eight 32-bit SHA-256 chaining values *before* that slice's bytes are hashed
/// (`hashCtx`). CryptoKit doesn't expose that, so this is a small self-contained SHA-256.
/// Slice offsets are always multiples of 64 bytes, so the midstate is exact at boundaries.
public struct SHA256Midstate {
    public static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var h0: UInt32 = 0x6a09e667, h1: UInt32 = 0xbb67ae85, h2: UInt32 = 0x3c6ef372, h3: UInt32 = 0xa54ff53a
    private var h4: UInt32 = 0x510e527f, h5: UInt32 = 0x9b05688c, h6: UInt32 = 0x1f83d9ab, h7: UInt32 = 0x5be0cd19
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var bufferCount = 0
    private var totalBytes: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: 64)

    public init() {}

    /// Chaining values after all *complete* 64-byte blocks fed so far.
    /// Only meaningful as a slice `hashCtx` when the bytes consumed are a multiple of 64.
    public var midstate: [UInt32] { [h0, h1, h2, h3, h4, h5, h6, h7] }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(UnsafeRawBufferPointer($0)) }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        var offset = 0
        let count = bytes.count
        totalBytes &+= UInt64(count)

        if bufferCount > 0 {
            let take = min(64 - bufferCount, count)
            for i in 0..<take { buffer[bufferCount + i] = bytes[i] }
            bufferCount += take
            offset = take
            if bufferCount == 64 {
                buffer.withUnsafeBytes { compress(UnsafeRawPointer($0.baseAddress!)) }
                bufferCount = 0
            }
        }
        while count - offset >= 64 {
            compress(base + offset)
            offset += 64
        }
        if offset < count {
            for i in offset..<count { buffer[bufferCount] = bytes[i]; bufferCount += 1 }
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = totalBytes &* 8
        var pad: [UInt8] = [0x80]
        let padZeros = (bufferCount < 56) ? (55 - bufferCount) : (119 - bufferCount)
        pad += [UInt8](repeating: 0, count: padZeros)
        for i in (0..<8).reversed() { pad.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        let savedTotal = totalBytes
        pad.withUnsafeBytes { update($0) }
        totalBytes = savedTotal
        precondition(bufferCount == 0)
        var out = [UInt8]()
        out.reserveCapacity(32)
        for v in midstate {
            out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff))
        }
        return out
    }

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func compress(_ p: UnsafeRawPointer) {
        w.withUnsafeMutableBufferPointer { w in
            for i in 0..<16 {
                w[i] = UInt32(bigEndian: p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
            }
            for i in 16..<64 {
                let a = w[i - 15], b = w[i - 2]
                let s0 = Self.rotr(a, 7) ^ Self.rotr(a, 18) ^ (a >> 3)
                let s1 = Self.rotr(b, 17) ^ Self.rotr(b, 19) ^ (b >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            Self.k.withUnsafeBufferPointer { k in
                for i in 0..<64 {
                    let S1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ S1 &+ ch &+ k[i] &+ w[i]
                    let S0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
                    let mj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = S0 &+ mj
                    h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                }
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d; h4 &+= e; h5 &+= f; h6 &+= g; h7 &+= h
        }
    }
}

public extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

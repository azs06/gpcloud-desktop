import CommonCrypto
import Foundation

/// SHA-256 with midstate access, backed by CommonCrypto (hardware accelerated, ~2 GB/s) when its
/// context layout is verified to expose the chaining values, else the portable `SHA256Midstate`.
public struct MidstateHasher {
    /// Verified once per process: CommonCrypto's `CC_SHA256_CTX.hash` must equal our reference midstate.
    public static let usesCommonCrypto: Bool = {
        var probe = [UInt8](repeating: 0, count: 192)
        for i in probe.indices { probe[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 11) }
        var cc = CC_SHA256_CTX()
        CC_SHA256_Init(&cc)
        CC_SHA256_Update(&cc, probe, CC_LONG(probe.count))
        var ref = SHA256Midstate()
        probe.withUnsafeBytes { ref.update($0) }
        return ccState(cc) == ref.midstate
    }()

    private var cc = CC_SHA256_CTX()
    private var portable = SHA256Midstate()
    private let fast: Bool

    public init() {
        fast = Self.usesCommonCrypto
        if fast { CC_SHA256_Init(&cc) }
    }

    public var midstate: [UInt32] { fast ? Self.ccState(cc) : portable.midstate }

    public mutating func update(_ data: Data) {
        if fast {
            data.withUnsafeBytes { p in _ = CC_SHA256_Update(&cc, p.baseAddress, CC_LONG(p.count)) }
        } else {
            portable.update(data)
        }
    }

    public mutating func finalize() -> [UInt8] {
        if fast {
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256_Final(&out, &cc)
            return out
        }
        return portable.finalize()
    }

    private static func ccState(_ c: CC_SHA256_CTX) -> [UInt32] {
        withUnsafeBytes(of: c.hash) { Array($0.bindMemory(to: UInt32.self)) }
    }
}

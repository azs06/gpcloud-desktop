import CryptoKit
import Foundation
import GPCloudKit

// Offline checks for the upload math. Run: swift run -c release gpcloud-selftest
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok   \(msg)") } else { print("  FAIL \(msg)"); failures += 1 }
}

print("SHA-256 vs CryptoKit")
for size in [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 1000, 4096, 1_048_577] {
    var bytes = [UInt8](repeating: 0, count: size)
    for i in 0..<size { bytes[i] = UInt8.random(in: 0...255) }
    var h = SHA256Midstate()
    // feed in odd-sized pieces to exercise buffering
    var i = 0
    while i < size { let n = min(size - i, Int.random(in: 1...777)); bytes[i..<(i + n)].withUnsafeBytes { h.update($0) }; i += n }
    check(h.finalize().hexString == SHA256.hash(data: Data(bytes)).hexString, "size \(size)")
}

print("Midstate")
check(SHA256Midstate().midstate == SHA256Midstate.initialState, "fresh hasher midstate is the SHA-256 IV")
// Known vector: midstate after one block of 64 zero bytes
var z = SHA256Midstate(); z.update(Data(count: 64))
check(z.midstate[0] == 0xda5698be, "midstate after 64 zero bytes (h0 = 0xda5698be)")

print("Slice sizes")
let MB: Int64 = 1_048_576
check(UploadPlanner.sliceSize(forFileSize: 38) == 38, "tiny file = single slice of its size")
check(UploadPlanner.sliceSize(forFileSize: 6 * MB) == 5 * MB, "6 MB → 5 MB slices")
check(UploadPlanner.sliceSize(forFileSize: 400 * MB) == 8 * MB, "400 MB → 8 MB slices")
check(UploadPlanner.sliceSize(forFileSize: 3000 * MB) == 50 * MB, "3 GB → 50 MB slices")
check(UploadPlanner.sliceSize(forFileSize: 20000 * MB) == 200 * MB, "20 GB → 200 MB slices")

print("Plan for a 6 MB + 123 B file")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gpcloud selftest.bin")
var blob = Data(count: Int(6 * MB) + 123)
blob.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) } }
try blob.write(to: tmp)
let plan = try UploadPlanner.makePlan(for: tmp, cloudUserId: "1234567890")
check(plan.slices.count == 2, "2 slices")
check(plan.slices[0].hashCtx == SHA256Midstate.initialState, "slice 1 hashCtx = IV")
var ref = SHA256Midstate(); ref.update(blob.prefix(Int(5 * MB)))
check(plan.slices[1].hashCtx == ref.midstate, "slice 2 hashCtx = midstate after 5 MB")
check(plan.slices[1].offset == 5 * MB && plan.slices[1].size == MB + 123, "slice 2 offset/size")
check(plan.sha256 == SHA256.hash(data: blob).hexString, "whole-file sha256")
check(plan.fileName == "gpcloud_selftest.bin", "space in name sanitized to underscore")
check(plan.proofCode.count == 64, "proofCode is a sha256 hex")
try? FileManager.default.removeItem(at: tmp)

print("Name rules")
check(NameRules.validationError("My Folder") != nil, "spaces rejected")
check(NameRules.validationError("My-Folder") == nil, "dashes accepted")
check(NameRules.sanitize("a<b>c d?.txt") == "abc_d.txt", "sanitize")

print("Fast hasher")
check(MidstateHasher.usesCommonCrypto, "CommonCrypto context exposes the SHA-256 midstate")
var fastH = MidstateHasher(); var slowH = SHA256Midstate()
let sample = Data((0..<(3 * 64 * 1000)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
fastH.update(sample); slowH.update(sample)
check(fastH.midstate == slowH.midstate, "fast and portable midstates agree")
check(fastH.finalize() == slowH.finalize(), "fast and portable digests agree")

print("Throughput")
let big = Data(count: 256 * Int(MB))
for (label, run) in [("portable", { var h = SHA256Midstate(); h.update(big); _ = h.finalize() }),
                     ("fast", { var h = MidstateHasher(); h.update(big); _ = h.finalize() })] as [(String, () -> Void)] {
    let t0 = Date(); run()
    print(String(format: "  %@: %.0f MB/s", label, 256 / Date().timeIntervalSince(t0)))
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

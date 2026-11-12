import CryptoKit
import Foundation

/// Everything `create-file-meta` needs, computed locally from the file.
public struct UploadPlan: Sendable {
    public struct Slice: Sendable, Equatable {
        public let partNumber: Int      // 1-based
        public let offset: Int64
        public let size: Int64
        public let hashCtx: [UInt32]    // SHA-256 midstate *before* this slice
    }

    public let fileURL: URL
    public let fileName: String
    public let mimeType: String
    public let fileType: String
    public let totalSize: Int64
    public let sha256: String
    public let proofCode: String
    public let slices: [Slice]
}

public enum UploadPlannerError: LocalizedError {
    case emptyFile
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "GP Cloud doesn't accept empty (0-byte) files."
        case .unreadable(let url): return "Couldn't read \(url.lastPathComponent)."
        }
    }
}

public enum UploadPlanner {
    /// Slice size table from the Android app (GenerateUploadSliceUseCase), rounded down to 64 bytes.
    public static func sliceSize(forFileSize size: Int64) -> Int64 {
        let mb: Int64 = 1_048_576
        let chosen: Int64
        switch size {
        case ...(100 * mb): chosen = 5 * mb
        case ...(500 * mb): chosen = 8 * mb
        case ...(2048 * mb): chosen = 10 * mb
        case ...(5120 * mb): chosen = 50 * mb
        case ...(10240 * mb): chosen = 100 * mb
        default: chosen = 200 * mb
        }
        return min(size, (chosen / 64) * 64)
    }

    /// proofCode = sha256(file[off ..< off+8]) where off is derived from sha256(hex(sha256(cloudUserId))).
    /// Lets the server confirm the client really has the bytes (used for rapid/dedup uploads).
    public static func proofCode(cloudUserId: String, fileSize: Int64, readBytes: (Int64, Int) throws -> Data) rethrows -> String {
        let seed = SHA256.hash(data: Data(cloudUserId.utf8)).hexString
        var digest = Array(SHA256.hash(data: Data(seed.utf8)))
        digest[24] &= 0x7f
        var offset: Int64 = 0
        for i in 24..<32 { offset = (offset << 8) | Int64(digest[i]) }
        if offset > fileSize { offset %= fileSize }
        let count = Int(min(offset + 8, fileSize) - offset)
        let sample = try readBytes(offset, count)
        return SHA256.hash(data: sample).hexString
    }

    public static func fileType(forMime mime: String, fileExtension ext: String) -> String {
        let ext = ext.lowercased()
        if mime.hasPrefix("image/") { return "PICTURE" }
        if mime.hasPrefix("video/") { return "VIDEO" }
        if mime.hasPrefix("audio/") { return "AUDIO" }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(ext) { return "WORD" }
        if ["xls", "xlsx", "ods", "csv", "numbers"].contains(ext) { return "EXCEL" }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { return "PPT" }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(ext) { return "ARCHIVE" }
        if ["apk", "exe", "dmg", "pkg", "msi", "app"].contains(ext) { return "APPLICATION" }
        return "OTHER"
    }

    /// One streaming pass over the file: full SHA-256 + per-slice midstates + proofCode.
    public static func makePlan(
        for url: URL,
        cloudUserId: String,
        isCancelled: () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) throws -> UploadPlan {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw UploadPlannerError.emptyFile }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw UploadPlannerError.unreadable(url) }
        defer { try? handle.close() }

        let sliceSize = sliceSize(forFileSize: size)
        var hasher = MidstateHasher()
        var slices: [UploadPlan.Slice] = []
        var offset: Int64 = 0
        var partNumber = 1
        let chunk = 4 * 1_048_576 // multiple of 64, so slice boundaries always land on block edges

        while offset < size {
            let thisSlice = min(sliceSize, size - offset)
            slices.append(.init(partNumber: partNumber, offset: offset, size: thisSlice, hashCtx: hasher.midstate))
            var remaining = thisSlice
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let want = Int(min(Int64(chunk), remaining))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else {
                    throw UploadPlannerError.unreadable(url)
                }
                hasher.update(data)
                remaining -= Int64(data.count)
                offset += Int64(data.count)
                progress?(Double(offset) / Double(size))
            }
            partNumber += 1
        }
        let sha = hasher.finalize().hexString

        let proof = try proofCode(cloudUserId: cloudUserId, fileSize: size) { off, count in
            try handle.seek(toOffset: UInt64(off))
            return try handle.read(upToCount: count) ?? Data()
        }

        let ext = url.pathExtension
        let mime = MimeTypes.mimeType(forExtension: ext)
        return UploadPlan(
            fileURL: url,
            fileName: NameRules.sanitize(url.lastPathComponent),
            mimeType: mime,
            fileType: fileType(forMime: mime, fileExtension: ext),
            totalSize: size,
            sha256: sha,
            proofCode: proof,
            slices: slices
        )
    }
}

/// GP Cloud name rules. Server regex: ^(?!\.{1,2}$)(?!.*[<>|:"*?\/\s]).{1,250}$
public enum NameRules {
    private static let forbidden = CharacterSet(charactersIn: "<>|:\"*?/\\")

    public static func validationError(_ name: String) -> String? {
        if name.isEmpty { return "Name can't be empty." }
        if name == "." || name == ".." { return "Name can't be “.” or “..”." }
        if name.count > 250 { return "Name must be 250 characters or fewer." }
        if name.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return "GP Cloud doesn't allow spaces in names." }
        if name.rangeOfCharacter(from: forbidden) != nil { return "Name can't contain < > | : \" * ? / \\" }
        return nil
    }

    /// Spaces become "_", other forbidden characters are dropped.
    public static func sanitize(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { out.append("_") }
            else if forbidden.contains(scalar) { continue }
            else { out.unicodeScalars.append(scalar) }
        }
        if out.isEmpty || out == "." || out == ".." { out = "untitled" }
        if out.count > 250 {
            let ext = (out as NSString).pathExtension
            let base = (out as NSString).deletingPathExtension
            let keep = 250 - (ext.isEmpty ? 0 : ext.count + 1)
            out = String(base.prefix(max(1, keep))) + (ext.isEmpty ? "" : "." + ext)
        }
        return out
    }
}

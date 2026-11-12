import Foundation
import UniformTypeIdentifiers

/// Standard GP Cloud response envelope: {data, success, code, status, message, errorMessages, pageInfo}
public struct Envelope<T: Decodable>: Decodable {
    public let data: T?
    public let success: Bool?
    public let code: Int?
    public let status: String?
    public let message: String?
    public let errorMessages: [ErrorMessage]?

    public struct ErrorMessage: Decodable { public let message: String?; public let details: String? }

    public var errorText: String {
        errorMessages?.compactMap { $0.message }.first ?? message ?? status ?? "Unknown error"
    }
}

public struct Empty: Decodable {}

public struct CloudFile: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let fileName: String
    public let fileType: String?
    public let fileSuffix: String?
    public let mimeType: String?
    public let parentFolder: [String]?
    public let fileSize: Int64?
    public let recycled: Bool?
    public let favorite: Bool?
    public let createdTime: String?
    public let editedTime: String?
    public let downloadLinks: [DownloadLink]?

    public struct DownloadLink: Decodable, Hashable, Sendable {
        public let usage: String?
        public let downloadLink: String?
    }

    public static let folderMime = "application/vnd.huawei-apps.folder"

    public var isFolder: Bool { mimeType == Self.folderMime || fileType == "FOLDER" }
    public var isFavorite: Bool { favorite ?? false }
    public var parentId: String? { parentFolder?.first }

    public var contentURL: URL? { link("content") }
    public var thumbnailURL: URL? { link("thumbnail") }

    private func link(_ usage: String) -> URL? {
        downloadLinks?.first(where: { $0.usage == usage })?.downloadLink.flatMap(URL.init(string:))
    }

    /// Name without the extension (rename takes the base name; the server re-appends fileSuffix).
    public var baseName: String {
        guard !isFolder, let suffix = fileSuffix, !suffix.isEmpty, fileName.hasSuffix("." + suffix) else { return fileName }
        return String(fileName.dropLast(suffix.count + 1))
    }

    public var modified: Date? { GPDate.parseUTC(editedTime) ?? GPDate.parseUTC(createdTime) }
    public var created: Date? { GPDate.parseUTC(createdTime) }

    public var utType: UTType? {
        if isFolder { return .folder }
        if let ext = fileSuffix, !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
        if let m = mimeType, let t = UTType(mimeType: m) { return t }
        return nil
    }

    public static func == (a: CloudFile, b: CloudFile) -> Bool {
        a.id == b.id && a.fileName == b.fileName && a.favorite == b.favorite && a.editedTime == b.editedTime && a.parentFolder == b.parentFolder
    }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct FileList: Decodable { public let files: [CloudFile]?; public let nextPageCursor: String? }

public struct RecentList: Decodable {
    public let files: [RecentEntry]?
    public struct RecentEntry: Decodable, Sendable {
        public let action: String?
        public let actionAt: String?
        public let fileId: String?
        public let metadata: Metadata?
        public struct Metadata: Decodable, Sendable {
            public let fileId: String?; public let fileName: String?; public let fileSize: Int64?; public let fileType: String?
        }
    }
}

public struct SpaceInfo: Decodable, Sendable {
    public let cloudUserId: String?
    public let capacity: Int64?
    public let spaceUsed: Int64?
}

public struct UserProfile: Decodable, Sendable {
    public let id: Int64?
    public let name: String?
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let mobileNumber: String?
    public let userName: String?

    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        if !full.isEmpty { return full }
        return mobileNumber ?? userName ?? "GP Cloud"
    }
}

public struct CreateFolderResult: Decodable { public let id: String?; public let folderName: String? }

public struct CreateFileMetaResult: Decodable {
    public let exist: Bool?
    public let rapidUpload: Bool?
    public let fileId: String?
    public let fileName: String?
    public let uploadId: String?
    public let multiParts: [Part]?
    public struct Part: Decodable { public let partNumber: Int?; public let partOffset: Int64?; public let partSize: Int64?; public let uploadUrl: String?; public let hashCtx: [String]? }
}

public struct PublicShare: Decodable { public let shareId: String?; public let shortUrl: String?; public let shortUrlId: String?; public let expireAt: String? }

public enum GPDate {
    private static let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss.SS", "yyyy-MM-dd'T'HH:mm:ss.S", "yyyy-MM-dd'T'HH:mm:ss"]
    private static func formatter(_ f: String, _ tz: TimeZone) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = f
        return df
    }
    private static let utc = formats.map { formatter($0, TimeZone(identifier: "UTC")!) }
    private static let dhaka = formats.map { formatter($0, TimeZone(identifier: "Asia/Dhaka")!) }

    /// File timestamps (createdTime/editedTime) are UTC without a zone suffix.
    public static func parseUTC(_ s: String?) -> Date? { parse(s, utc) }
    /// Recent-activity timestamps (actionAt) are Bangladesh local time.
    public static func parseDhaka(_ s: String?) -> Date? { parse(s, dhaka) }

    private static func parse(_ s: String?, _ fs: [DateFormatter]) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        for f in fs { if let d = f.date(from: s) { return d } }
        return nil
    }
}

public enum MimeTypes {
    public static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

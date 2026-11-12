import Foundation

public protocol TokenProvider: AnyObject, Sendable {
    /// Returns a bearer token. `forceRefresh` is set after the server answered 401.
    func accessToken(forceRefresh: Bool) async throws -> String
    /// Called when the gateway still answers 401 after a forced refresh.
    func tokenRejected() async
}

public extension TokenProvider {
    func tokenRejected() async {}
}

public enum GPCloudError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case api(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You're signed out of GP Cloud."
        case .http(let code, let msg): return "Server error \(code): \(msg)"
        case .api(let msg): return msg
        case .decoding(let msg): return "Unexpected response: \(msg)"
        }
    }
}

/// Client for the GP Cloud API.
///
/// Requests go through the web app's same-origin proxy (`/api/gateway/...`), which forwards to
/// `aloapis.grameenphone.com/apigw/...`. The bearer token is the NextAuth session `accessToken`.
public final class GPCloudAPI: @unchecked Sendable {
    public static let webOrigin = URL(string: "https://gpcloud.grameenphone.com")!
    public static let gatewayBase = URL(string: "https://gpcloud.grameenphone.com/api/gateway")!

    private let tokens: TokenProvider
    private let session: URLSession
    private let deviceId: String

    public init(tokens: TokenProvider, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
        let key = "GPCloudDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) {
            deviceId = id
        } else {
            let id = UUID().uuidString.lowercased()
            UserDefaults.standard.set(id, forKey: key)
            deviceId = id
        }
    }

    // MARK: - Core request

    private func headers(token: String) -> [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-APP-NAME": "GP Cloud",
            "X-APP-PACKAGE-NAME": "gpcloud.grameenphone.com",
            "X-APP-VERSION": "0.1.0",
            "X-DEVICE-ID": deviceId,
            "X-DEVICE-VENDOR": "Apple",
            "X-DEVICE-MODEL": "GPCloud macOS",
            "X-DEVICE-OS-VERSION": "macOS \(os.majorVersion).\(os.minorVersion)",
        ]
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: JSONBody? = nil, as: T.Type = T.self) async throws -> Envelope<T> {
        let url = URL(string: Self.gatewayBase.absoluteString + path)!
        var bodyData: Data?
        if let body { bodyData = try JSONSerialization.data(withJSONObject: body.value) }

        for attempt in 0..<2 {
            let token = try await tokens.accessToken(forceRefresh: attempt > 0)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = bodyData
            req.timeoutInterval = 60
            for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }

            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 {
                // Either the session is really gone (auth manager will sign out) or the gateway
                // rejects this route (it answers 401 with an empty body for unknown routes).
                await tokens.tokenRejected()
                let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
                throw GPCloudError.http(401, text.isEmpty ? "GP Cloud rejected this request." : text)
            }

            let env: Envelope<T>
            do {
                env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            } catch {
                let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
                if !(200..<300).contains(status) { throw GPCloudError.http(status, text) }
                throw GPCloudError.decoding("\(error) – \(text)")
            }
            if env.success == false || !(200..<300).contains(status) {
                throw GPCloudError.api(env.errorText)
            }
            return env
        }
        throw GPCloudError.notSignedIn
    }

    private func data<T: Decodable>(_ path: String, method: String = "GET", body: JSONBody? = nil, as type: T.Type = T.self) async throws -> T {
        let env = try await send(path, method: method, body: body, as: type)
        guard let d = env.data else { throw GPCloudError.decoding("missing data") }
        return d
    }

    private func perform(_ path: String, method: String, body: JSONBody? = nil) async throws {
        _ = try await send(path, method: method, body: body, as: Empty.self)
    }

    private static let v1 = "/gpcloud/edge/api/v1"

    // MARK: - Account

    public func spaceInfo() async throws -> SpaceInfo { try await data("\(Self.v1)/profile/user-space-info/1") }
    public func profile() async throws -> UserProfile { try await data("/iam/edge/api/v1/users/profile") }

    // MARK: - Browsing

    public func file(id: String) async throws -> CloudFile { try await data("\(Self.v1)/files/\(id)") }

    /// Lists a folder ("root" works as an alias for the root folder). Follows page cursors.
    public func list(folderId: String, recycled: Bool = false) async throws -> [CloudFile] {
        var all: [CloudFile] = []
        var cursor: String?
        repeat {
            var page: [String: Any] = ["pageSize": 100]
            if let cursor { page["pageCursor"] = cursor }
            let body: [String: Any] = ["parentFolderId": folderId, "recycled": recycled, "pageInfo": page]
            let res: FileList = try await data("\(Self.v1)/files", method: "POST", body: JSONBody(body))
            all += res.files ?? []
            cursor = res.nextPageCursor
        } while cursor?.isEmpty == false
        return all
    }

    public func trash() async throws -> [CloudFile] {
        var all: [CloudFile] = []
        var cursor: String?
        repeat {
            var page: [String: Any] = ["pageSize": 100]
            if let cursor { page["pageCursor"] = cursor }
            let res: FileList = try await data("\(Self.v1)/files", method: "POST", body: JSONBody(["recycled": true, "pageInfo": page]))
            all += res.files ?? []
            cursor = res.nextPageCursor
        } while cursor?.isEmpty == false
        return all
    }

    public func search(_ keyword: String, inTrash: Bool = false) async throws -> [CloudFile] {
        let body: [String: Any] = ["keyWord": keyword, "recycled": inTrash, "pageInfo": ["pageSize": 100]]
        let res: FileList = try await data("\(Self.v1)/files/search", method: "POST", body: JSONBody(body))
        return res.files ?? []
    }

    public func favorites() async throws -> [CloudFile] {
        var all: [CloudFile] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["pageSize": 100]
            if let cursor { body["pageCursor"] = cursor }
            let res: FileList = try await data("\(Self.v1)/files/favorite", method: "POST", body: JSONBody(body))
            all += res.files ?? []
            cursor = res.nextPageCursor
        } while cursor?.isEmpty == false
        return all
    }

    public func recent() async throws -> [RecentList.RecentEntry] {
        let res: RecentList = try await data("\(Self.v1)/files/recent")
        return res.files ?? []
    }

    // MARK: - Mutations

    @discardableResult
    public func createFolder(name: String, parentId: String) async throws -> String? {
        let res: CreateFolderResult = try await data("\(Self.v1)/files/create/folder", method: "POST",
                                                     body: JSONBody(["name": name, "parentFolder": parentId]))
        return res.id
    }

    /// `newName` excludes the extension; the server keeps the original suffix.
    public func rename(id: String, newName: String) async throws {
        try await perform("\(Self.v1)/files/rename/\(id)", method: "PUT",
                          body: JSONBody(["newName": newName, "duplicateFilePolicy": "FORCE_RENAME"]))
    }

    public func move(ids: [String], to folderId: String) async throws {
        try await perform("\(Self.v1)/files/move", method: "PUT",
                          body: JSONBody(["items": ids.map { ["fileId": $0] }, "newFilePath": folderId]))
    }

    public func copy(ids: [String], to folderId: String) async throws {
        try await perform("\(Self.v1)/files/copy", method: "POST",
                          body: JSONBody(["items": ids.map { ["fileId": $0] }, "newFilePath": folderId]))
    }

    /// `permanent: false` moves to Trash (policy LOGICAL).
    public func delete(_ files: [CloudFile], permanent: Bool) async throws {
        let items = files.map { ["fileId": $0.id, "filePath": "\($0.parentId ?? "root")/\($0.id)"] }
        try await perform("\(Self.v1)/files/delete", method: "DELETE",
                          body: JSONBody(["items": items, "policy": permanent ? "PERMANENT" : "LOGICAL"]))
    }

    public func restore(ids: [String]) async throws {
        try await perform("\(Self.v1)/files/restore", method: "POST", body: JSONBody(["items": ids]))
    }

    public func emptyTrash() async throws {
        try await perform("\(Self.v1)/files/trash-empty", method: "DELETE")
    }

    public func setFavorite(ids: [String], favorite: Bool) async throws {
        try await perform("\(Self.v1)/files/favorite/mark-favorite", method: "PUT",
                          body: JSONBody(["items": ids, "favorite": favorite]))
    }

    /// Public share link. `validityDays` is a best guess at the unit (untested against the live API).
    public func createPublicLink(id: String, validityDays: Int = 7) async throws -> PublicShare {
        try await data("\(Self.v1)/files/share/public", method: "POST", body: JSONBody(["item": id, "validity": validityDays]))
    }

    // MARK: - Upload primitives

    public func createFileMeta(plan: UploadPlan, parentId: String) async throws -> CreateFileMetaResult {
        let parts: [[String: Any]] = plan.slices.map {
            ["hashCtx": $0.hashCtx.map { String($0) }, "partNumber": $0.partNumber, "partOffset": $0.offset, "partSize": $0.size]
        }
        let body: [String: Any] = [
            "duplicateFilePolicy": "FORCE_RENAME",
            "fileName": plan.fileName,
            "fileType": plan.fileType,
            "mimeType": plan.mimeType,
            "multiParts": parts,
            "parentFolder": [parentId],
            "totalSize": plan.totalSize,
            "sha256": plan.sha256,
            "proofCode": plan.proofCode,
            "uploadMode": "multipart",
            "uploadType": "MULTIPART",
        ]
        return try await data("\(Self.v1)/files/create-file-meta", method: "POST", body: JSONBody(body))
    }

    public func completeUpload(fileId: String) async throws {
        try await perform("\(Self.v1)/files/complete-status/\(fileId)", method: "GET")
    }
}

// MARK: - JSON helpers

public struct JSONBody {
    let value: Any
    init(_ value: Any) { self.value = value }
}

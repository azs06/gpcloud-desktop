import AppKit
import Foundation
import GPCloudKit

@MainActor
final class TransferItem: ObservableObject, Identifiable {
    enum Kind { case upload, download }
    enum Status: Equatable {
        case queued, hashing(Double), transferring(Double), finishing, done(String?), failed(String), cancelled
        var isActive: Bool {
            switch self { case .queued, .hashing, .transferring, .finishing: return true; default: return false }
        }
    }

    let id = UUID()
    let name: String
    let kind: Kind
    let localURL: URL
    let size: Int64
    @Published var status: Status = .queued
    var task: Task<Void, Never>?

    init(name: String, kind: Kind, localURL: URL, size: Int64) {
        self.name = name; self.kind = kind; self.localURL = localURL; self.size = size
    }

    var fraction: Double {
        switch status {
        case .hashing(let p): return p * 0.1
        case .transferring(let p): return kind == .upload ? 0.1 + p * 0.88 : p
        case .finishing: return 0.99
        case .done: return 1
        default: return 0
        }
    }

    var statusText: String {
        switch status {
        case .queued: return "Waiting…"
        case .hashing: return "Preparing…"
        case .transferring: return kind == .upload ? "Uploading…" : "Downloading…"
        case .finishing: return "Finishing…"
        case .done(let note): return note ?? (kind == .upload ? "Uploaded" : "Downloaded")
        case .failed(let msg): return msg
        case .cancelled: return "Cancelled"
        }
    }
}

@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var items: [TransferItem] = []
    @Published var panelVisible = false

    private let api: GPCloudAPI
    private let engine: UploadEngine
    private weak var drive: DriveModel?
    private var cloudUserId: String?

    private var runningUploads = 0
    private var pendingUploads: [(TransferItem, String)] = []
    private let maxParallelUploads = 2

    private var runningDownloads = 0
    private var pendingDownloads: [(TransferItem, CloudFile)] = []
    private let maxParallelDownloads = 3
    /// Destination paths handed out but not yet written, so a batch never picks the same name twice.
    private var reservedPaths = Set<String>()

    private var refreshTask: Task<Void, Never>?
    /// Bumped on reset so work from a previous account can't touch the new one.
    private var generation = 0

    init(api: GPCloudAPI, drive: DriveModel) {
        self.api = api
        self.engine = UploadEngine(api: api)
        self.drive = drive
    }

    var activeCount: Int { items.filter { $0.status.isActive }.count }

    func clearFinished() { items.removeAll { !$0.status.isActive } }

    func cancel(_ item: TransferItem) {
        item.task?.cancel()
        pendingUploads.removeAll { $0.0.id == item.id }
        pendingDownloads.removeAll { $0.0.id == item.id }
        if item.status.isActive { item.status = .cancelled }
    }

    /// Sign-out: stop everything and forget the account.
    func reset() {
        generation += 1
        for item in items where item.status.isActive { cancel(item) }
        pendingUploads.removeAll()
        pendingDownloads.removeAll()
        items.removeAll()
        cloudUserId = nil
        panelVisible = false
        refreshTask?.cancel()
    }

    /// Coalesce list/storage refreshes while many transfers finish.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let drive = self?.drive else { return }
            await drive.reload()
            await drive.refreshAccount()
        }
    }

    // MARK: - Uploads

    /// Accepts files and folders. Folders are recreated remotely, then their files queued.
    func upload(_ urls: [URL], to folderId: String) {
        panelVisible = true
        let gen = generation
        Task {
            for url in urls { await enqueue(url, into: folderId, generation: gen) }
        }
    }

    private func enqueue(_ url: URL, into folderId: String, generation gen: Int) async {
        guard gen == generation else { return }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        if values?.isSymbolicLink == true { return } // never follow links (cycles, surprises)
        guard let isDir = values?.isDirectory else { return }
        if isDir {
            let name = NameRules.sanitize(url.lastPathComponent)
            do {
                guard let newId = try await api.createFolder(name: name, parentId: folderId) else { return }
                scheduleRefresh()
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
                for child in children { await enqueue(child, into: newId, generation: gen) }
            } catch {
                let item = TransferItem(name: url.lastPathComponent, kind: .upload, localURL: url, size: 0)
                item.status = .failed(error.localizedDescription)
                items.insert(item, at: 0)
            }
            return
        }
        let size = Int64(values?.fileSize ?? 0)
        let item = TransferItem(name: url.lastPathComponent, kind: .upload, localURL: url, size: size)
        items.insert(item, at: 0)
        pendingUploads.append((item, folderId))
        pumpUploads()
    }

    private func pumpUploads() {
        while runningUploads < maxParallelUploads, !pendingUploads.isEmpty {
            let (item, folderId) = pendingUploads.removeFirst()
            guard item.status == .queued else { continue }
            runningUploads += 1
            item.task = Task { [weak self] in
                await self?.runUpload(item, folderId: folderId)
                self?.runningUploads -= 1
                self?.pumpUploads()
            }
        }
    }

    private func runUpload(_ item: TransferItem, folderId: String) async {
        do {
            let uid = try await userId()
            let engine = self.engine
            _ = try await engine.upload(fileURL: item.localURL, to: folderId, cloudUserId: uid) { phase in
                Task { @MainActor in
                    guard item.status.isActive else { return }
                    switch phase {
                    case .hashing(let p): item.status = .hashing(p)
                    case .uploading(let p): item.status = .transferring(p)
                    case .finishing: item.status = .finishing
                    case .done(_, let rapid): item.status = .done(rapid ? "Uploaded (instant)" : nil)
                    }
                }
            }
            // Ensure a final state even if the last phase hop hasn't landed yet.
            await Task.yield()
            if item.status.isActive { item.status = .done(nil) }
            scheduleRefresh()
        } catch {
            if error is CancellationError || Task.isCancelled { item.status = .cancelled }
            else { item.status = .failed(error.localizedDescription) }
        }
    }

    private func userId() async throws -> String {
        if let cloudUserId { return cloudUserId }
        let gen = generation
        guard let id = try await api.spaceInfo().cloudUserId else { throw GPCloudError.api("Couldn't read your cloud user id") }
        if gen == generation { cloudUserId = id }
        return id
    }

    // MARK: - Downloads

    func download(_ files: [CloudFile], to directory: URL) {
        panelVisible = true
        for file in files where !file.isFolder {
            let dest = uniqueURL(directory.appendingPathComponent(file.fileName))
            reservedPaths.insert(dest.path)
            let item = TransferItem(name: dest.lastPathComponent, kind: .download, localURL: dest, size: file.fileSize ?? 0)
            items.insert(item, at: 0)
            pendingDownloads.append((item, file))
        }
        pumpDownloads()
    }

    private func pumpDownloads() {
        while runningDownloads < maxParallelDownloads, !pendingDownloads.isEmpty {
            let (item, file) = pendingDownloads.removeFirst()
            guard item.status == .queued else { reservedPaths.remove(item.localURL.path); continue }
            runningDownloads += 1
            item.task = Task { [weak self] in
                await self?.runDownload(item, file: file)
                self?.reservedPaths.remove(item.localURL.path)
                self?.runningDownloads -= 1
                self?.pumpDownloads()
            }
        }
    }

    private func runDownload(_ item: TransferItem, file: CloudFile) async {
        guard let drive else { return }
        item.status = .transferring(0)
        do {
            try await drive.downloadFile(file, to: item.localURL) { p in
                Task { @MainActor in if item.status.isActive { item.status = .transferring(p) } }
            }
            if item.status.isActive { item.status = .done(nil) }
        } catch {
            if item.status.isActive {
                item.status = (error is CancellationError || Task.isCancelled) ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reservedPaths.contains(candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

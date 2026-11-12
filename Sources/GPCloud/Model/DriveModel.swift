import AppKit
import Foundation
import GPCloudKit
import SwiftUI

enum DriveSection: String, Hashable, CaseIterable, Identifiable {
    case myDrive, recent, starred, trash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .myDrive: return "My Drive"
        case .recent: return "Recent"
        case .starred: return "Starred"
        case .trash: return "Trash"
        }
    }
    var symbol: String {
        switch self {
        case .myDrive: return "externaldrive.fill"
        case .recent: return "clock"
        case .starred: return "star"
        case .trash: return "trash"
        }
    }
}

struct Crumb: Hashable { let id: String; let name: String }

enum SortKey: String, CaseIterable, Identifiable {
    case name, modified, size
    var id: String { rawValue }
    var title: String { switch self { case .name: return "Name"; case .modified: return "Last modified"; case .size: return "Size" } }
}

@MainActor
final class DriveModel: ObservableObject {
    let api: GPCloudAPI

    @Published var section: DriveSection = .myDrive { didSet { if oldValue != section { sectionChanged() } } }
    @Published var path: [Crumb] = [Crumb(id: "root", name: "My Drive")]
    @Published private(set) var items: [CloudFile] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selection: Set<String> = []
    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published var sortKey: SortKey = .name { didSet { items = sorted(items) } }
    @Published var sortAscending = true { didSet { items = sorted(items) } }
    @Published private(set) var space: SpaceInfo?
    @Published private(set) var profile: UserProfile?
    @Published var quickLookURL: URL?
    @Published var busyMessage: String?
    /// True when the items on screen came from Trash. Menus and Delete key key off this, not `section`,
    /// so a stale or mismatched list can never offer "Delete Forever" on live files.
    @Published private(set) var itemsFromTrash = false

    private var loadGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var rootFolderId: String?

    init(api: GPCloudAPI) { self.api = api }

    var currentFolderId: String { path.last?.id ?? "root" }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    var canCreateHere: Bool { section == .myDrive && !isSearching }

    var selectedFiles: [CloudFile] { items.filter { selection.contains($0.id) } }

    // MARK: - Loading

    func start() async {
        async let s: () = refreshAccount()
        async let r: () = reload()
        _ = await (s, r)
    }

    func refreshAccount() async {
        if DemoMode.enabled { space = DemoMode.space; profile = DemoMode.profile; return }
        if let s = try? await api.spaceInfo() { space = s }
        if let p = try? await api.profile() { profile = p }
    }

    func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        defer { if gen == loadGeneration { isLoading = false } }
        if DemoMode.enabled {
            let fresh = DemoMode.items(section: section, folderId: currentFolderId, search: isSearching ? searchText : "")
            itemsFromTrash = section == .trash
            items = section == .recent && !isSearching ? fresh : sorted(fresh)
            return
        }
        do {
            let result: [CloudFile]
            let fromTrash = section == .trash
            if isSearching {
                result = try await api.search(searchText.trimmingCharacters(in: .whitespaces), inTrash: fromTrash)
            } else {
                switch section {
                case .myDrive: result = try await api.list(folderId: currentFolderId)
                case .starred: result = try await api.favorites()
                case .trash: result = try await api.trash()
                case .recent: result = try await recentFiles()
                }
            }
            guard gen == loadGeneration else { return }
            itemsFromTrash = fromTrash
            items = section == .recent && !isSearching ? result : sorted(result)
            selection = selection.intersection(Set(items.map(\.id)))
        } catch {
            guard gen == loadGeneration else { return }
            if case GPCloudError.notSignedIn = error { return }
            errorMessage = error.localizedDescription
        }
    }

    func recentFiles(limit: Int = 40) async throws -> [CloudFile] {
        if DemoMode.enabled { return Array(DemoMode.recent.prefix(limit)) }
        let entries = try await api.recent()
        var seen = Set<String>()
        let ids = entries.compactMap { $0.metadata?.fileId ?? $0.fileId }.filter { seen.insert($0).inserted }.prefix(limit)
        let api = self.api
        let files = await withTaskGroup(of: (Int, CloudFile?).self) { group in
            for (i, id) in ids.enumerated() { group.addTask { (i, try? await api.file(id: id)) } }
            var out: [(Int, CloudFile)] = []
            for await (i, f) in group { if let f { out.append((i, f)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // The root folder shows up in recent views; hide it and anything already trashed.
        if rootFolderId == nil { rootFolderId = try? await api.file(id: "root").id }
        let root = rootFolderId
        return files.filter { $0.id != root && $0.recycled != true }
    }

    private func sorted(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let asc: Bool
            switch sortKey {
            case .name: asc = a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            case .modified: asc = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: asc = (a.fileSize ?? 0) < (b.fileSize ?? 0)
            }
            return sortAscending ? asc : !asc
        }
    }

    private func sectionChanged() {
        clearListing()
        if section == .myDrive { path = [Crumb(id: "root", name: "My Drive")] }
        if !searchText.isEmpty { searchText = "" }
        Task { await reload() }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    // MARK: - Navigation

    /// Drop what's on screen so actions can't target a list from the previous location.
    private func clearListing() {
        items = []
        selection = []
        itemsFromTrash = false
    }

    func open(_ file: CloudFile) {
        guard !itemsFromTrash, file.recycled != true else { return }
        if file.isFolder {
            if section != .myDrive || isSearching {
                // Jump into My Drive at that folder. We don't know its ancestry, so start from root.
                searchText = ""
                section = .myDrive
                path = [Crumb(id: "root", name: "My Drive")]
            }
            path.append(Crumb(id: file.id, name: file.fileName))
            clearListing()
            Task { await reload() }
        } else {
            Task { await openLocally(file, quickLook: false) }
        }
    }

    func goTo(crumbIndex: Int) {
        guard crumbIndex < path.count else { return }
        path = Array(path.prefix(crumbIndex + 1))
        clearListing()
        Task { await reload() }
    }

    func goUp() { if path.count > 1 { goTo(crumbIndex: path.count - 2) } }

    // MARK: - Actions

    func createFolder(named name: String) async {
        await run("Creating folder…") {
            try await self.api.createFolder(name: name, parentId: self.currentFolderId)
        }
    }

    func rename(_ file: CloudFile, to newBaseName: String) async {
        await run("Renaming…") { try await self.api.rename(id: file.id, newName: newBaseName) }
    }

    func moveToTrash(_ files: [CloudFile]) async {
        guard !files.isEmpty else { return }
        await run("Moving to Trash…") { try await self.api.delete(files, permanent: false) }
        await refreshAccount()
    }

    func deleteForever(_ files: [CloudFile]) async {
        guard !files.isEmpty else { return }
        await run("Deleting…") { try await self.api.delete(files, permanent: true) }
        await refreshAccount()
    }

    func restore(_ files: [CloudFile]) async {
        await run("Restoring…") { try await self.api.restore(ids: files.map(\.id)) }
        await refreshAccount()
    }

    func emptyTrash() async {
        await run("Emptying Trash…") { try await self.api.emptyTrash() }
        await refreshAccount()
    }

    func setStar(_ files: [CloudFile], _ on: Bool) async {
        await run(nil) { try await self.api.setFavorite(ids: files.map(\.id), favorite: on) }
    }

    func move(_ files: [CloudFile], to folderId: String) async {
        await run("Moving…") { try await self.api.move(ids: files.map(\.id), to: folderId) }
    }

    func copy(_ files: [CloudFile], to folderId: String) async {
        await run("Copying…") { try await self.api.copy(ids: files.map(\.id), to: folderId) }
        await refreshAccount()
    }

    func copyShareLink(_ file: CloudFile) async {
        busyMessage = "Creating link…"
        defer { busyMessage = nil }
        do {
            let share = try await api.createPublicLink(id: file.id)
            guard let link = share.shortUrl else { throw GPCloudError.api("No link returned") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            busyMessage = "Link copied"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ message: String?, _ op: @escaping () async throws -> Void) async {
        busyMessage = message
        defer { busyMessage = nil }
        var failure: String?
        do {
            try await op()
        } catch {
            failure = error.localizedDescription
        }
        await reload()
        if let failure { errorMessage = failure }
    }

    /// Forget everything about the signed-in account.
    func reset() {
        loadGeneration += 1
        searchTask?.cancel()
        section = .myDrive
        path = [Crumb(id: "root", name: "My Drive")]
        clearListing()
        searchText = ""
        space = nil
        profile = nil
        rootFolderId = nil
        errorMessage = nil
        quickLookURL = nil
        isLoading = false
    }

    // MARK: - Local files (open / Quick Look / download)

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GPCloud/Open", isDirectory: true)
    }

    /// Download to the cache (re-using it if already there) and open or preview.
    func openLocally(_ file: CloudFile, quickLook: Bool) async {
        guard !file.isFolder, !DemoMode.enabled else { return }
        let dir = Self.cacheDir.appendingPathComponent(file.id, isDirectory: true)
        let dest = dir.appendingPathComponent(file.fileName)
        if !FileManager.default.fileExists(atPath: dest.path) {
            busyMessage = "Downloading \(file.fileName)…"
            defer { busyMessage = nil }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await downloadFile(file, to: dest)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if quickLook { quickLookURL = dest } else { NSWorkspace.shared.open(dest) }
    }

    /// Fetches fresh presigned links (they expire) then downloads.
    func downloadFile(_ file: CloudFile, to destination: URL, progress: ((Double) -> Void)? = nil) async throws {
        let fresh = try await api.file(id: file.id)
        guard let url = fresh.contentURL ?? file.contentURL else { throw GPCloudError.api("No download link for \(file.fileName)") }
        let tmp = try await Downloader.shared.download(url, progress: progress)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}

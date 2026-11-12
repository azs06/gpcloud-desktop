import AppKit
import GPCloudKit
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String { case grid, list }

enum NameSheetMode: Identifiable {
    case newFolder
    case rename(CloudFile)
    var id: String { switch self { case .newFolder: return "new"; case .rename(let f): return "rename-\(f.id)" } }
}

struct FolderPickRequest: Identifiable {
    enum Op { case move, copy }
    let id = UUID()
    let op: Op
    let files: [CloudFile]
}

struct BrowserView: View {
    @EnvironmentObject var drive: DriveModel
    @EnvironmentObject var transfers: TransferManager
    @AppStorage("viewMode") private var viewMode: ViewMode = .grid
    @State private var nameSheet: NameSheetMode?
    @State private var folderPick: FolderPickRequest?
    @State private var confirmDeleteForever: [CloudFile]?
    @State private var confirmEmptyTrash = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            ZStack {
                content
                if drive.isLoading && drive.items.isEmpty {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Key handling lives on the content (not the whole view) so typing in the search field isn't hijacked.
            .onDeleteCommand {
                let sel = drive.selectedFiles
                guard !sel.isEmpty else { return }
                if drive.itemsFromTrash { confirmDeleteForever = sel } else { Task { await drive.moveToTrash(sel) } }
            }
            .onKeyPress(.space) {
                guard let f = drive.selectedFiles.first, !f.isFolder, !drive.itemsFromTrash else { return .ignored }
                if drive.quickLookURL != nil { drive.quickLookURL = nil } else { Task { await drive.openLocally(f, quickLook: true) } }
                return .handled
            }
            .onKeyPress(.return) {
                guard drive.selectedFiles.count == 1, let f = drive.selectedFiles.first else { return .ignored }
                drive.open(f)
                return .handled
            }
            .overlay {
                if dropTargeted && drive.canCreateHere {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label("Drop to upload to “\(drive.path.last?.name ?? "My Drive")”", systemImage: "arrow.up.doc")
                                    .font(.title3).padding(12).background(.regularMaterial, in: Capsule()))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard drive.canCreateHere else { return false }
                loadURLs(from: providers) { urls in transfers.upload(urls, to: drive.currentFolderId) }
                return true
            }
        }
        .navigationTitle(drive.isSearching ? "Search" : (drive.section == .myDrive ? (drive.path.last?.name ?? "My Drive") : drive.section.title))
        .searchable(text: $drive.searchText, placement: .toolbar, prompt: "Search in GP Cloud")
        .toolbar { toolbarContent }
        .sheet(item: $nameSheet) { mode in
            NameSheet(mode: mode) { name in
                switch mode {
                case .newFolder: Task { await drive.createFolder(named: name) }
                case .rename(let f): Task { await drive.rename(f, to: name) }
                }
            }
        }
        .sheet(item: $folderPick) { req in
            FolderPickerSheet(title: req.op == .move ? "Move \(Self.describe(req.files)) to…" : "Copy \(Self.describe(req.files)) to…",
                              actionTitle: req.op == .move ? "Move Here" : "Copy Here",
                              excluding: Set(req.files.filter(\.isFolder).map(\.id))) { folderId in
                Task {
                    if req.op == .move { await drive.move(req.files, to: folderId) } else { await drive.copy(req.files, to: folderId) }
                }
            }
            .environmentObject(drive)
        }
        .confirmationDialog("Delete \(Self.describe(confirmDeleteForever ?? [])) forever?",
                            isPresented: Binding(get: { confirmDeleteForever != nil }, set: { if !$0 { confirmDeleteForever = nil } })) {
            Button("Delete Forever", role: .destructive) {
                let files = confirmDeleteForever ?? []
                Task { await drive.deleteForever(files) }
            }
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { Task { await drive.emptyTrash() } }
        } message: { Text("All items in Trash will be deleted forever. This can't be undone.") }
        .alert("Something went wrong", isPresented: Binding(get: { drive.errorMessage != nil }, set: { if !$0 { drive.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(drive.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .gpNewFolder)) { _ in if drive.canCreateHere { nameSheet = .newFolder } }
        .onReceive(NotificationCenter.default.publisher(for: .gpUpload)) { _ in chooseUploads() }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if drive.items.isEmpty && !drive.isLoading {
            EmptyStateView(section: drive.section, searching: drive.isSearching,
                           onUpload: drive.canCreateHere ? { chooseUploads() } : nil)
        } else if viewMode == .grid {
            GridContent(menu: { menuItems(for: $0) })
        } else {
            ListContent(menu: { menuItems(for: $0) })
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { drive.goUp() } label: { Image(systemName: "chevron.left") }
                .help("Enclosing folder")
                .disabled(drive.section != .myDrive || drive.path.count <= 1 || drive.isSearching)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if drive.canCreateHere {
                Menu {
                    Button { nameSheet = .newFolder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { chooseUploads() } label: { Label("Upload Files or Folders…", systemImage: "arrow.up.doc") }
                } label: {
                    Label("New", systemImage: "plus")
                } primaryAction: {
                    chooseUploads()
                }
                .help("Upload (click) or create (hold)")
            }
            if drive.section == .trash && drive.itemsFromTrash && !drive.items.isEmpty {
                Button("Empty Trash") { confirmEmptyTrash = true }
            }
            Menu {
                Picker("Sort by", selection: $drive.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $drive.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Grid or list")
            Button { Task { await drive.reload(); await drive.refreshAccount() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
        }
    }

    // MARK: - Context menu

    @ViewBuilder func menuItems(for files: [CloudFile]) -> some View {
        let single = files.count == 1 ? files.first : nil
        let onlyFiles = files.filter { !$0.isFolder }
        if drive.itemsFromTrash {
            Button("Restore") { Task { await drive.restore(files) } }
            Button("Delete Forever…", role: .destructive) { confirmDeleteForever = files }
        } else {
            if let f = single {
                Button(f.isFolder ? "Open" : "Open") { drive.open(f) }
                if !f.isFolder {
                    Button("Quick Look") { Task { await drive.openLocally(f, quickLook: true) } }
                }
                Divider()
            }
            if !onlyFiles.isEmpty {
                Button("Download\(onlyFiles.count > 1 ? " \(onlyFiles.count) Files" : "")") { downloadToDownloads(onlyFiles) }
                Button("Download To…") { download(onlyFiles) }
            }
            if let f = single {
                Button("Rename…") { nameSheet = .rename(f) }
            }
            let allStarred = files.allSatisfy(\.isFavorite)
            Button(allStarred ? "Remove from Starred" : "Add to Starred") { Task { await drive.setStar(files, !allStarred) } }
            Divider()
            Button("Move To…") { folderPick = .init(op: .move, files: files) }
            Button("Copy To…") { folderPick = .init(op: .copy, files: files) }
            if let f = single, !f.isFolder {
                Button("Copy Public Link") { Task { await drive.copyShareLink(f) } }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await drive.moveToTrash(files) } }
        }
    }

    // MARK: - Helpers

    static func describe(_ files: [CloudFile]) -> String {
        files.count == 1 ? "“\(files[0].fileName)”" : "\(files.count) items"
    }

    private func chooseUploads() {
        guard drive.canCreateHere else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to “\(drive.path.last?.name ?? "My Drive")”"
        let folderId = drive.currentFolderId
        if panel.runModal() == .OK { transfers.upload(panel.urls, to: folderId) }
    }

    private func downloadToDownloads(_ files: [CloudFile]) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        transfers.download(files, to: dir)
    }

    private func download(_ files: [CloudFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if panel.runModal() == .OK, let dir = panel.url { transfers.download(files, to: dir) }
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { completion(urls) } }
    }
}

// MARK: - Header (breadcrumbs + status)

struct HeaderBar: View {
    @EnvironmentObject var drive: DriveModel

    var body: some View {
        HStack(spacing: 4) {
            if drive.isSearching {
                Text("Results for “\(drive.searchText)”").font(.title3.weight(.semibold))
            } else if drive.section == .myDrive {
                ForEach(Array(drive.path.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(crumb.name) { drive.goTo(crumbIndex: i) }
                        .buttonStyle(.plain)
                        .font(i == drive.path.count - 1 ? .title3.weight(.semibold) : .title3)
                        .foregroundStyle(i == drive.path.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
            } else {
                Text(drive.section.title).font(.title3.weight(.semibold))
                if drive.section == .trash {
                    Text("Items in Trash can be restored").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                }
            }
            Spacer()
            if let msg = drive.busyMessage {
                ProgressView().controlSize(.small)
                Text(msg).font(.caption).foregroundStyle(.secondary)
            } else if drive.isLoading && !drive.items.isEmpty {
                ProgressView().controlSize(.small)
            }
            Text("\(drive.items.count) item\(drive.items.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Grid

struct GridContent<Menu: View>: View {
    @EnvironmentObject var drive: DriveModel
    let menu: ([CloudFile]) -> Menu
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            let folders = drive.items.filter(\.isFolder)
            let files = drive.items.filter { !$0.isFolder }
            VStack(alignment: .leading, spacing: 18) {
                if !folders.isEmpty {
                    sectionHeader("Folders")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(folders) { f in FolderChip(file: f).modifier(SelectableItem(file: f, menu: menu, onSelect: { focused = true })) }
                    }
                }
                if !files.isEmpty {
                    sectionHeader("Files")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                        ForEach(files) { f in FileTile(file: f).modifier(SelectableItem(file: f, menu: menu, onSelect: { focused = true })) }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
        .onTapGesture { drive.selection = []; focused = true }
        // Focusable so Space / Return / Delete reach the key handlers in grid mode.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// Click = select, ⌘-click = toggle, double-click = open, right-click = menu for the selection.
struct SelectableItem<Menu: View>: ViewModifier {
    @EnvironmentObject var drive: DriveModel
    let file: CloudFile
    let menu: ([CloudFile]) -> Menu
    var onSelect: () -> Void = {}

    func body(content: Content) -> some View {
        let selected = drive.selection.contains(file.id)
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .gesture(TapGesture(count: 2).onEnded { drive.open(file) })
            .simultaneousGesture(TapGesture().onEnded {
                onSelect()
                if NSEvent.modifierFlags.contains(.command) {
                    if selected { drive.selection.remove(file.id) } else { drive.selection.insert(file.id) }
                } else {
                    drive.selection = [file.id]
                }
            })
            .contextMenu {
                let targets = selected ? drive.selectedFiles : [file]
                menu(targets)
            }
    }
}

struct FolderChip: View {
    let file: CloudFile
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue)
            Text(file.fileName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if file.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct FileTile: View {
    let file: CloudFile
    var body: some View {
        VStack(spacing: 0) {
            FilePreview(file: file)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipped()
            HStack(spacing: 6) {
                FileIcon(file: file, size: 16)
                Text(file.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if file.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .help("\(file.fileName)\n\(Fmt.bytes(file.fileSize ?? 0)) · \(Fmt.date(file.modified))")
    }
}

// MARK: - List

struct ListContent<Menu: View>: View {
    @EnvironmentObject var drive: DriveModel
    let menu: ([CloudFile]) -> Menu

    var body: some View {
        Table(drive.items, selection: $drive.selection) {
            TableColumn("Name") { f in
                HStack(spacing: 8) {
                    FileIcon(file: f, size: 18)
                    Text(f.fileName).lineLimit(1).truncationMode(.middle)
                    if f.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
            }
            .width(min: 220, ideal: 380)
            TableColumn("Last modified") { f in Text(Fmt.date(f.modified)).foregroundStyle(.secondary) }
                .width(min: 100, ideal: 140)
            TableColumn("Size") { f in Text(f.isFolder ? "—" : Fmt.bytes(f.fileSize ?? 0)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Kind") { f in Text(f.utType?.localizedDescription ?? (f.fileSuffix?.uppercased() ?? "Document")).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let files = drive.items.filter { ids.contains($0.id) }
            if !files.isEmpty { menu(files) }
        } primaryAction: { ids in
            if ids.count == 1, let f = drive.items.first(where: { ids.contains($0.id) }) { drive.open(f) }
        }
    }
}

// MARK: - Icons & previews

struct FileIcon: View {
    let file: CloudFile
    let size: CGFloat
    var body: some View {
        if file.isFolder {
            Image(systemName: "folder.fill").foregroundStyle(.blue).font(.system(size: size * 0.9))
                .frame(width: size, height: size)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: file.utType ?? .data))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

struct FilePreview: View {
    let file: CloudFile
    var body: some View {
        let showsThumb = ["PICTURE", "VIDEO"].contains(file.fileType ?? "") || (file.utType?.conforms(to: .image) ?? false)
        if showsThumb, let url = file.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure: FileIcon(file: file, size: 56)
                default: ProgressView().controlSize(.small)
                }
            }
        } else {
            FileIcon(file: file, size: 64)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let section: DriveSection
    let searching: Bool
    let onUpload: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 54)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let onUpload {
                Button("Upload Files…", action: onUpload).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(40)
    }

    private var symbol: String {
        if searching { return "magnifyingglass" }
        switch section { case .myDrive: return "icloud.and.arrow.up"; case .recent: return "clock"; case .starred: return "star"; case .trash: return "trash" }
    }
    private var title: String {
        if searching { return "No results" }
        switch section { case .myDrive: return "Drop files here"; case .recent: return "No recent files"; case .starred: return "No starred files"; case .trash: return "Trash is empty" }
    }
    private var subtitle: String {
        if searching { return "Try a different search." }
        switch section {
        case .myDrive: return "Drag files or folders into this window, or use the Upload button."
        case .recent: return "Files you open or upload will show up here."
        case .starred: return "Star files and folders to find them quickly."
        case .trash: return "Items you delete will be kept here until you empty the Trash."
        }
    }
}

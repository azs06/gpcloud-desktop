import GPCloudKit
import SwiftUI

/// New-folder / rename sheet with GP Cloud's name rules (no spaces, no <>|:"*?/\).
struct NameSheet: View {
    let mode: NameSheetMode
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var title: String {
        switch mode { case .newFolder: return "New Folder"; case .rename: return "Rename" }
    }
    private var suffix: String? {
        if case .rename(let f) = mode, !f.isFolder, let s = f.fileSuffix, !s.isEmpty, f.fileName.hasSuffix("." + s) { return s }
        return nil
    }
    private var error: String? { name.isEmpty ? nil : NameRules.validationError(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            HStack(spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                if let suffix { Text(".\(suffix)").foregroundStyle(.secondary) }
            }
            .frame(width: 340)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                if name.rangeOfCharacter(from: .whitespaces) != nil {
                    Button("Replace spaces with underscores") { name = NameRules.sanitize(name) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(title == "Rename" ? "Rename" : "Create", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || error != nil)
            }
        }
        .padding(20)
        .onAppear {
            switch mode {
            case .newFolder: name = "Untitled-folder"
            case .rename(let f): name = f.baseName
            }
            focused = true
        }
    }

    private func commit() {
        guard !name.isEmpty, error == nil else { return }
        onCommit(name)
        dismiss()
    }
}

/// Browse your folders to pick a destination for Move / Copy.
struct FolderPickerSheet: View {
    let title: String
    let actionTitle: String
    let excluding: Set<String>
    let onPick: (String) -> Void

    @EnvironmentObject var drive: DriveModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = [Crumb(id: "root", name: "My Drive")]
    @State private var folders: [CloudFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                Button { if path.count > 1 { path.removeLast(); Task { await load() } } } label: { Image(systemName: "chevron.left") }
                    .disabled(path.count <= 1)
                ForEach(Array(path.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(c.name) { path = Array(path.prefix(i + 1)); Task { await load() } }
                        .buttonStyle(.plain).foregroundStyle(i == path.count - 1 ? .primary : .secondary).lineLimit(1)
                }
                Spacer()
            }
            List(selection: $selected) {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                ForEach(folders) { f in
                    Label(f.fileName, systemImage: "folder.fill")
                        .tag(f.id)
                        .foregroundStyle(excluding.contains(f.id) ? .tertiary : .primary)
                }
                if !loading && folders.isEmpty { Text("No folders here").foregroundStyle(.secondary) }
            }
            // Double-click enters a folder (native List primary action; doesn't fight single-click selection).
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
                guard let id = ids.first, !excluding.contains(id), let f = folders.first(where: { $0.id == id }) else { return }
                path.append(Crumb(id: f.id, name: f.fileName))
                Task { await load() }
            })
            .frame(height: 260)
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text(destinationLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    onPick(destinationId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(excluding.contains(destinationId))
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
        .onChange(of: path) { _, _ in selected = nil }
    }

    private var destinationId: String {
        if let selected, !excluding.contains(selected) { return selected }
        return path.last?.id ?? "root"
    }
    private var destinationLabel: String {
        if let selected, let f = folders.first(where: { $0.id == selected }) { return "Destination: \(f.fileName)" }
        return "Destination: \(path.last?.name ?? "My Drive")"
    }

    private func load() async {
        let target = path.last?.id ?? "root"
        loading = true
        folders = []
        defer { if target == (path.last?.id ?? "root") { loading = false } }
        do {
            let result = try await drive.api.list(folderId: target).filter(\.isFolder)
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            guard target == (path.last?.id ?? "root") else { return } // a newer load superseded this one
            folders = result
            error = nil
        } catch {
            guard target == (path.last?.id ?? "root") else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Google-Drive-style transfer card in the bottom-right corner.
struct TransfersPanel: View {
    @EnvironmentObject var transfers: TransferManager
    @State private var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headline).font(.callout.weight(.semibold))
                Spacer()
                Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                Button {
                    if transfers.activeCount == 0 { transfers.clearFinished() }
                    transfers.panelVisible = false
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !collapsed {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.items) { item in
                            TransferRow(item: item)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var headline: String {
        let active = transfers.activeCount
        if active > 0 { return "Transferring \(active) item\(active == 1 ? "" : "s")" }
        let failed = transfers.items.filter { if case .failed = $0.status { return true }; return false }.count
        if failed > 0 { return "\(failed) transfer\(failed == 1 ? "" : "s") failed" }
        return "\(transfers.items.count) transfer\(transfers.items.count == 1 ? "" : "s") complete"
    }
}

struct TransferRow: View {
    @ObservedObject var item: TransferItem
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(item.kind == .upload ? .blue : .green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if item.status.isActive {
                    ProgressView(value: item.fraction).controlSize(.small)
                }
                Text(subtitle).font(.caption).foregroundStyle(isFailed ? .red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var isFailed: Bool { if case .failed = item.status { return true }; return false }

    private var subtitle: String {
        if item.size > 0, item.status.isActive {
            return "\(item.statusText) \(Fmt.bytes(Int64(Double(item.size) * item.fraction))) of \(Fmt.bytes(item.size))"
        }
        return item.statusText
    }

    @ViewBuilder private var trailing: some View {
        switch item.status {
        case .done:
            if item.kind == .download {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless).help("Show in Finder")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            EmptyView()
        default:
            Button { transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
        }
    }
}

import AppKit
import GPCloudKit
import ServiceManagement
import SwiftUI

/// Menu bar icon: reflects activity (idle / transferring / signed out).
struct MenuBarLabel: View {
    @ObservedObject var transfers: TransferManager
    @ObservedObject var auth: AuthManager

    var body: some View {
        if auth.state != .signedIn {
            Image(systemName: "icloud.slash")
        } else if transfers.activeCount > 0 {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
        } else {
            Image(systemName: "cloud")
        }
    }
}

/// The popover shown from the menu bar icon.
struct MenuBarContent: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var drive: DriveModel
    @EnvironmentObject var transfers: TransferManager
    @Environment(\.openWindow) private var openWindow

    @State private var recent: [CloudFile] = []
    @State private var loadingRecent = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if auth.state == .signedIn {
                signedInBody
            } else {
                VStack(spacing: 10) {
                    Text(auth.state == .checking ? "Connecting…" : "You're signed out.")
                        .foregroundStyle(.secondary)
                    if auth.state == .signedOut {
                        Button("Sign In…") { showMainWindow(); auth.beginLogin() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .task(id: auth.state) { await loadRecent() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.fill")
                .font(.title2)
                .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 1) {
                Text("GP Cloud").font(.headline)
                if auth.state == .signedIn, let name = drive.profile?.displayName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showMainWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless).help("Open GP Cloud window")
        }
        .padding(12)
    }

    @ViewBuilder private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageView(space: drive.space)

            HStack(spacing: 8) {
                Button { uploadFromMenu() } label: {
                    Label("Upload…", systemImage: "arrow.up.doc").frame(maxWidth: .infinity)
                }
                Button { showMainWindow() } label: {
                    Label("Open Drive", systemImage: "externaldrive").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            if !transfers.items.isEmpty {
                HStack {
                    Text(transfers.activeCount > 0 ? "Transferring \(transfers.activeCount)" : "Transfers")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if transfers.activeCount < transfers.items.count {
                        Button("Clear") { transfers.clearFinished() }.buttonStyle(.link).font(.caption)
                    }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(transfers.items.prefix(20)) { TransferRow(item: $0).padding(.horizontal, -14) }
                    }
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if loadingRecent { ProgressView().controlSize(.mini) }
            }
            if recent.isEmpty && !loadingRecent {
                Text("No recent files").font(.callout).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(recent.prefix(6)) { file in
                        RecentRow(file: file) {
                            if file.isFolder { showMainWindow(); drive.open(file) }
                            else { Task { await drive.openLocally(file, quickLook: false) } }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                .toggleStyle(.checkbox)
                .font(.callout)
            if let loginItemError {
                Text(loginItemError).font(.caption2).foregroundStyle(.red)
            }
            HStack {
                if auth.state == .signedIn {
                    Button("Sign Out") { Task { await auth.signOut() } }.buttonStyle(.link)
                }
                Spacer()
                Button("Quit GP Cloud") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(GPCloudApp.mainWindowID) == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: GPCloudApp.mainWindowID)
        }
    }

    private func uploadFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to My Drive"
        if panel.runModal() == .OK { transfers.upload(panel.urls, to: "root") }
    }

    private func loadRecent() async {
        guard auth.state == .signedIn else { recent = []; return }
        loadingRecent = true
        defer { loadingRecent = false }
        if drive.space == nil || drive.profile == nil { await drive.refreshAccount() }
        recent = (try? await drive.recentFiles(limit: 8)) ?? recent
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change login item: \(error.localizedDescription). Move the app to /Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct RecentRow: View {
    let file: CloudFile
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                FileIcon(file: file, size: 18)
                Text(file.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Fmt.date(file.modified)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

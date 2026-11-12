import GPCloudKit
import QuickLook
import SwiftUI

struct MainView: View {
    @EnvironmentObject var drive: DriveModel
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            BrowserView()
        }
        .overlay(alignment: .bottomTrailing) {
            if transfers.panelVisible && !transfers.items.isEmpty {
                TransfersPanel()
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: transfers.panelVisible)
        .quickLookPreview($drive.quickLookURL)
    }
}

struct SidebarView: View {
    @EnvironmentObject var drive: DriveModel
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        List(selection: Binding(get: { drive.section }, set: { if let s = $0 { drive.section = s } })) {
            Section {
                ForEach(DriveSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                StorageView(space: drive.space)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(drive.profile?.displayName ?? "GP Cloud").font(.callout.weight(.medium)).lineLimit(1)
                        if let phone = drive.profile?.mobileNumber, phone != drive.profile?.displayName {
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        if !transfers.items.isEmpty {
                            Button("Show Transfers") { transfers.panelVisible = true }
                        }
                        Button("Sign Out") { Task { await auth.signOut() } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(12)
        }
    }
}

struct StorageView: View {
    let space: SpaceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Storage", systemImage: "cloud").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let cap = space?.capacity, cap > 0 {
                let used = space?.spaceUsed ?? 0
                ProgressView(value: min(1, Double(used) / Double(cap)))
                    .tint(Double(used) / Double(cap) > 0.9 ? .red : .blue)
                Text("\(Fmt.bytes(used)) of \(Fmt.bytes(cap)) used")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView(value: 0)
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.month(.abbreviated).day()) }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

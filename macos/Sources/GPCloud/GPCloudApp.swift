import AppKit
import Combine
import GPCloudKit
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let auth: AuthManager
    let api: GPCloudAPI
    let drive: DriveModel
    let transfers: TransferManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        auth = AuthManager()
        api = GPCloudAPI(tokens: auth)
        drive = DriveModel(api: api)
        transfers = TransferManager(api: api, drive: drive)
        // Leaving the signed-in state wipes per-account state (folders, cached user id, transfers).
        auth.$state
            .removeDuplicates()
            .scan((AuthManager.State.checking, AuthManager.State.checking)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                guard let self, previous == .signedIn, current != .signedIn else { return }
                self.transfers.reset()
                self.drive.reset()
            }
            .store(in: &cancellables)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run), become a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        if DemoMode.enabled {
            // Screenshot runs: don't steal focus; honour the requested appearance.
            if let a = DemoMode.appearance { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    // Keep running in the menu bar when the window is closed (if the menu bar icon is enabled).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: GPCloudApp.menuBarKey, default: true)
    }

    // Clicking the Dock icon with no windows reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct GPCloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    @AppStorage(GPCloudApp.menuBarKey) private var showMenuBarIcon = true

    static let mainWindowID = "main"
    static let menuBarKey = "showMenuBarIcon"

    var body: some Scene {
        WindowGroup("GP Cloud", id: Self.mainWindowID) {
            RootView()
                .environmentObject(services)
                .environmentObject(services.auth)
                .environmentObject(services.drive)
                .environmentObject(services.transfers)
                .frame(minWidth: DemoMode.enabled && DemoMode.view == "menubar" ? 340 : 860,
                       minHeight: DemoMode.enabled && DemoMode.view == "menubar" ? 300 : 540)
        }
        .defaultSize(width: 1180, height: 740)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(auth: services.auth, drive: services.drive, showMenuBarIcon: $showMenuBarIcon) }

        MenuBarExtra(isInserted: DemoMode.enabled ? .constant(false) : $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(services)
                .environmentObject(services.auth)
                .environmentObject(services.drive)
                .environmentObject(services.transfers)
        } label: {
            MenuBarLabel(transfers: services.transfers, auth: services.auth)
        }
        .menuBarExtraStyle(.window)
    }
}

extension UserDefaults {
    func bool(forKey key: String, default def: Bool) -> Bool {
        object(forKey: key) == nil ? def : bool(forKey: key)
    }
}

struct AppCommands: Commands {
    // Observe the models directly so the enabled/disabled state actually updates.
    @ObservedObject var auth: AuthManager
    @ObservedObject var drive: DriveModel
    @Binding var showMenuBarIcon: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder…") { NotificationCenter.default.post(name: .gpNewFolder, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(auth.state != .signedIn || !drive.canCreateHere)
            Button("Upload Files or Folders…") { NotificationCenter.default.post(name: .gpUpload, object: nil) }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(auth.state != .signedIn || !drive.canCreateHere)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show in Menu Bar", isOn: $showMenuBarIcon)
            Divider()
            Button("Refresh") { Task { await drive.reload(); await drive.refreshAccount() } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(auth.state != .signedIn)
        }
        CommandMenu("Go") {
            ForEach(Array(DriveSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { drive.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command])
            }
            Divider()
            Button("Enclosing Folder") { drive.goUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(drive.path.count <= 1)
        }
    }
}

extension Notification.Name {
    static let gpNewFolder = Notification.Name("gpNewFolder")
    static let gpUpload = Notification.Name("gpUpload")
}

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var drive: DriveModel

    var body: some View {
        Group {
            if DemoMode.enabled {
                DemoRoot()
            } else {
                switch auth.state {
                case .signedIn:
                    MainView()
                        .task { await drive.start() }
                case .checking, .signedOut:
                    WelcomeView()
                }
            }
        }
        .animation(.default, value: auth.state)
    }
}

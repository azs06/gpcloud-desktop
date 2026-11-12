import AppKit
import Foundation
import GPCloudKit

/// Offline demo with made-up files, used to produce README screenshots without a real account.
///   GPCLOUD_DEMO=1                       enable
///   GPCLOUD_DEMO_VIEW=grid|list|menubar  what the window shows
///   GPCLOUD_DEMO_APPEARANCE=light|dark
enum DemoMode {
    static let enabled = ProcessInfo.processInfo.environment["GPCLOUD_DEMO"] == "1"
    static var view: String { ProcessInfo.processInfo.environment["GPCLOUD_DEMO_VIEW"] ?? "grid" }
    static var appearance: String? { ProcessInfo.processInfo.environment["GPCLOUD_DEMO_APPEARANCE"] }

    static let space: SpaceInfo = decode(["cloudUserId": "0", "capacity": 107_374_182_400, "spaceUsed": 25_125_558_272])
    static let profile: UserProfile = decode(["id": 1, "name": "Demo User", "mobileNumber": "Demo account"])

    static func items(section: DriveSection, folderId: String, search: String) -> [CloudFile] {
        if !search.isEmpty {
            return all.filter { $0.fileName.localizedCaseInsensitiveContains(search) }
        }
        switch section {
        case .myDrive: return folderId == "root" ? root : (children[folderId] ?? [])
        case .recent: return recent
        case .starred: return all.filter(\.isFavorite)
        case .trash: return trash
        }
    }

    static var recent: [CloudFile] { [root[4], root[6], root[9], root[5], root[7], root[8]] }

    // MARK: - Data

    private static let now = Date()
    private static func ago(_ hours: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.string(from: now.addingTimeInterval(-hours * 3600))
    }

    private static func folder(_ id: String, _ name: String, hours: Double, star: Bool = false) -> CloudFile {
        decode(["id": id, "fileName": name, "fileType": "FOLDER", "mimeType": CloudFile.folderMime,
                "parentFolder": ["root"], "favorite": star, "createdTime": ago(hours), "editedTime": ago(hours)])
    }

    private static func file(_ id: String, _ name: String, _ type: String, _ mime: String, size: Int64,
                             hours: Double, star: Bool = false, thumb: Thumb? = nil, parent: String = "root",
                             recycled: Bool = false) -> CloudFile {
        var links: [[String: String]] = []
        if let thumb, let url = thumbURL(thumb) { links.append(["usage": "thumbnail", "downloadLink": url.absoluteString]) }
        return decode(["id": id, "fileName": name, "fileType": type, "fileSuffix": (name as NSString).pathExtension,
                       "mimeType": mime, "parentFolder": [parent], "fileSize": size, "favorite": star,
                       "recycled": recycled, "createdTime": ago(hours + 30), "editedTime": ago(hours),
                       "downloadLinks": links])
    }

    static let root: [CloudFile] = [
        folder("f-docs", "Documents", hours: 3, star: true),
        folder("f-photos", "Photos", hours: 20),
        folder("f-projects", "Projects", hours: 50),
        folder("f-music", "Music", hours: 400),
        file("p1", "Coxs-Bazar-sunset.jpg", "PICTURE", "image/jpeg", size: 4_812_330, hours: 1.2, star: true, thumb: .sunset),
        file("p2", "Sajek-valley.jpg", "PICTURE", "image/jpeg", size: 6_204_118, hours: 5, thumb: .mountains),
        file("d1", "Annual-Report-2026.pdf", "OTHER", "application/pdf", size: 2_311_908, hours: 2),
        file("v1", "Family-trip.mp4", "VIDEO", "video/mp4", size: 412_993_211, hours: 26, thumb: .ocean),
        file("x1", "Budget-2026.xlsx", "EXCEL", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             size: 88_412, hours: 30, star: true),
        file("k1", "Pitch-Deck.pptx", "PPT", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
             size: 9_412_002, hours: 72),
        file("p3", "Tea-garden-Sylhet.jpg", "PICTURE", "image/jpeg", size: 5_118_004, hours: 100, thumb: .forest),
        file("z1", "Backup-2025.zip", "ARCHIVE", "application/zip", size: 1_204_993_118, hours: 700),
        file("t1", "Notes.txt", "OTHER", "text/plain", size: 4_120, hours: 0.3),
    ]

    private static let children: [String: [CloudFile]] = [
        "f-docs": [
            file("d2", "Passport-scan.pdf", "OTHER", "application/pdf", size: 912_004, hours: 300, parent: "f-docs"),
            file("d3", "Lease-agreement.docx", "WORD", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 size: 48_220, hours: 900, parent: "f-docs"),
        ],
        "f-photos": [
            file("p4", "Old-Dhaka.jpg", "PICTURE", "image/jpeg", size: 3_902_144, hours: 40, thumb: .dusk, parent: "f-photos"),
            file("p5", "Sundarbans.jpg", "PICTURE", "image/jpeg", size: 7_021_551, hours: 41, thumb: .forest, parent: "f-photos"),
        ],
    ]

    private static let trash: [CloudFile] = [
        file("r1", "Old-draft.docx", "WORD", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             size: 31_002, hours: 48, recycled: true),
        file("r2", "Screenshot-2026-10-01.png", "PICTURE", "image/png", size: 1_203_441, hours: 90, thumb: .dusk, recycled: true),
    ]

    private static var all: [CloudFile] { root + children.values.flatMap { $0 } }

    /// Fake transfers so the panel has something to show.
    @MainActor static func seedTransfers(_ t: TransferManager) {
        t.injectDemo([
            ("Wedding-album.zip", .upload, 1_820_441_002, .transferring(0.62)),
            ("Thesis-final.pdf", .upload, 8_220_114, .hashing(0.4)),
            ("Coxs-Bazar-sunset.jpg", .upload, 4_812_330, .done(nil)),
            ("Budget-2026.xlsx", .download, 88_412, .done(nil)),
        ])
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ dict: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(T.self, from: data)
    }

    enum Thumb: String { case sunset, mountains, ocean, forest, dusk }

    /// Paints a simple landscape PNG to a temp file (AsyncImage loads file:// URLs).
    private static func thumbURL(_ t: Thumb) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gpcloud-demo-\(t.rawValue).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (sky1, sky2, land, sun): (NSColor, NSColor, NSColor, NSColor?) = {
            switch t {
            case .sunset: return (.systemOrange, .systemPink, NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.25, alpha: 1), .systemYellow)
            case .mountains: return (.systemTeal, NSColor(calibratedRed: 0.75, green: 0.9, blue: 1, alpha: 1), NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.3, alpha: 1), .white)
            case .ocean: return (.systemBlue, .systemCyan, NSColor(calibratedRed: 0.0, green: 0.3, blue: 0.55, alpha: 1), .systemYellow)
            case .forest: return (NSColor(calibratedRed: 0.7, green: 0.9, blue: 0.75, alpha: 1), .systemMint, NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.2, alpha: 1), nil)
            case .dusk: return (.systemPurple, .systemIndigo, NSColor(calibratedRed: 0.1, green: 0.08, blue: 0.2, alpha: 1), .systemOrange)
            }
        }()
        let size = NSSize(width: 480, height: 320)
        let image = NSImage(size: size, flipped: false) { r in
            NSGradient(starting: sky1, ending: sky2)?.draw(in: r, angle: 90)
            if let sun {
                sun.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.width * 0.62, y: r.height * 0.5, width: 70, height: 70)).fill()
            }
            land.withAlphaComponent(0.75).setFill()
            let back = NSBezierPath()
            back.move(to: .zero)
            back.line(to: NSPoint(x: r.width * 0.3, y: r.height * 0.55))
            back.line(to: NSPoint(x: r.width * 0.55, y: r.height * 0.3))
            back.line(to: NSPoint(x: r.width * 0.8, y: r.height * 0.6))
            back.line(to: NSPoint(x: r.width, y: r.height * 0.35))
            back.line(to: NSPoint(x: r.width, y: 0))
            back.close(); back.fill()
            land.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: r.width, height: r.height * 0.22)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: url)
        return url
    }
}

import SwiftUI

/// What the window shows in demo mode.
struct DemoRoot: View {
    @EnvironmentObject var drive: DriveModel
    @EnvironmentObject var transfers: TransferManager
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        Group {
            if DemoMode.view == "menubar" {
                MenuBarContent()
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.onAppear { panelHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in panelHeight = h }
                    })
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            } else {
                MainView()
            }
        }
        .task {
            UserDefaults.standard.set(DemoMode.view == "list" ? "list" : "grid", forKey: "viewMode")
            await drive.start()
            if DemoMode.view == "grid" { drive.sortKey = .modified; drive.sortAscending = false }
            if DemoMode.view != "list" { DemoMode.seedTransfers(transfers) }
            drive.selection = [DemoMode.view == "list" ? "d1" : "p1"]
            if DemoMode.view == "menubar" {
                // Give the panel room to lay out at full height, then shrink the window to fit it.
                NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.setContentSize(NSSize(width: 340, height: 1000))
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            configureWindow()
        }
    }

    /// Fixed, reproducible window geometry for screenshots.
    @MainActor private func configureWindow() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        if DemoMode.view == "menubar" {
            // Borderless, transparent window so the capture is just the rounded panel (like the real popover).
            w.toolbar = nil
            w.styleMask = [.borderless]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.setContentSize(NSSize(width: 340, height: max(300, panelHeight)))
        } else {
            w.setContentSize(NSSize(width: 1240, height: 780))
        }
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

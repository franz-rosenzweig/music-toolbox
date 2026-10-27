import SwiftUI
import AppKit
import Observation

/// Music Toolbox: uploads music to the server, loads it onto devices, shows what a device cannot play.
@main
struct MusicToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Music Toolbox", id: "main") {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Upload Music…") { Nav.shared.place = .upload; Nav.shared.choose = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Needs You") { Nav.shared.place = .needs }.keyboardShortcut("1", modifiers: .command)
                Button("Upload") { Nav.shared.place = .upload }.keyboardShortcut("2", modifiers: .command)
                Button("Library") { Nav.shared.place = .library }.keyboardShortcut("3", modifiers: .command)
                Button("History") { Nav.shared.place = .history }.keyboardShortcut("4", modifiers: .command)
                Button("Activity") { Nav.shared.place = .activity }.keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Search") { Nav.shared.place = .library; Nav.shared.focusSearch.toggle() }.keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsForm().frame(width: 480).padding(.vertical, 8)
        }
    }
}

enum Place: Hashable {
    case needs
    case rip
    case history
    case activity
    case upload
    case library
    case device(String)
    case setup(String)
}

@Observable @MainActor
final class Nav {
    static let shared = Nav()
    var place: Place? = .needs
    var choose = false
    var needsSelection: String?
    var focusSearch = false
    var toast: Toast?
    var sessions: [String: DeviceSession] = [:]

    func session(for v: Volume) -> DeviceSession {
        if let s = sessions[v.id] { s.update(v); return s }
        let s = DeviceSession(v)
        sessions[v.id] = s
        return s
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let out = ProcessInfo.processInfo.environment["MUSIC_SELFTEST"] {
            QuietExit.install(log: out)
            Task { @MainActor in await SelfTest.run(out: URL(fileURLWithPath: out)) }
        }
    }

    /// Folders and music dropped on the Dock icon, or opened with the app from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Nav.shared.place = .upload
            await UploadStore.shared.add(urls)
        }
    }

    /// With "open for discs / players" on, the app keeps running with its window closed, to open it when one comes in.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Prefs.staysRunning }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

/// A test copy that hits an exception writes it down and leaves quietly: no crash report, no dialog
/// asking whether to reopen windows on the owner's screen.
enum QuietExit {
    nonisolated(unsafe) static var path = ""

    static func install(log: String) {
        path = log + "/crash.txt"
        NSSetUncaughtExceptionHandler { e in
            try? "\(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))".write(toFile: QuietExit.path, atomically: true, encoding: .utf8)
            _exit(70)
        }
    }
}

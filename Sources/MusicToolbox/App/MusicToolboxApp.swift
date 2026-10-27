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
                Button("Upload") { Nav.shared.place = .upload }.keyboardShortcut("1", modifiers: .command)
            }
        }

        Settings {
            SettingsForm().frame(width: 480).padding(.vertical, 8)
        }
    }
}

enum Place: Hashable {
    case upload
    case device(String)
    case setup(String)
}

@Observable @MainActor
final class Nav {
    static let shared = Nav()
    var place: Place? = .upload
    var choose = false
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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

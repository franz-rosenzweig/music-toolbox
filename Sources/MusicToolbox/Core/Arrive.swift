import AppKit
import ServiceManagement

/// What to do when a disc or a player comes in. The two switches are in Settings.
enum Prefs {
    static var openForDiscs: Bool { UserDefaults.standard.object(forKey: "openForDiscs") as? Bool ?? true }
    static var openForPlayers: Bool { UserDefaults.standard.object(forKey: "openForPlayers") as? Bool ?? true }
    /// With either on, closing the window leaves the app running, so there is something to show.
    static var staysRunning: Bool { openForDiscs || openForPlayers }
}

extension Nav {
    /// Something has just come in: show the app on it, opening the window if it was closed.
    func arrive(_ place: Place) {
        self.place = place
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}

/// Starting the app at login, so it is there to be shown when something comes in. It is a login item
/// the owner can also remove in System Settings.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

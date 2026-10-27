import Foundation
import Security

/// Sizes, rates and times as the panel writes them.
enum Fmt {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: max(0, n)) }

    static func rate(_ bytesPerSecond: Double) -> String { size(Int64(bytesPerSecond)) + "/s" }

    static func left(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s > 5400 ? "\(Int((Double(s) / 3600).rounded())) h" : s > 90 ? "\(Int((Double(s) / 60).rounded())) min" : "\(s) s"
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The password lives in the Keychain; everything else the app is told is in UserDefaults.
enum Keychain {
    static let service = Bundle.main.bundleIdentifier ?? "xyz.tiresia.musictoolbox"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// What the app has been told about the server. MUSIC_* environment variables win, for the
/// self-test; nothing about the owner's server is built into the app.
enum Config {
    static let defaults = UserDefaults.standard

    private static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var panelURL: URL? {
        var s = (env("MUSIC_PANEL_URL") ?? defaults.string(forKey: "panelURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    static var user: String { env("MUSIC_PANEL_USER") ?? defaults.string(forKey: "panelUser") ?? "" }
    static var password: String { env("MUSIC_PANEL_PASSWORD") ?? Keychain.get("panel") ?? "" }

    static var panel: Panel? {
        guard let url = panelURL, !user.isEmpty else { return nil }
        return Panel(base: url, user: user, password: password)
    }

    static var remote: Remote? {
        let target = (env("MUSIC_SSH_TARGET") ?? defaults.string(forKey: "sshTarget") ?? "").trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        func path(_ key: String, _ fallback: String) -> String {
            let v = (env("MUSIC_" + key.uppercased()) ?? defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? fallback : v
        }
        return Remote(target: target,
                      musicPath: path("musicPath", "/srv/media/music"),
                      queuePath: path("queuePath", "/srv/docker/beets/config/dap-queue.txt"),
                      syncLogPath: path("syncLogPath", "/srv/docker/beets/config/dap-sync-log.jsonl"))
    }
}

/// Keeps the Mac awake while something long runs.
@MainActor
final class Awake {
    private var token: NSObjectProtocol?
    private var users = 0

    static let shared = Awake()

    func hold(_ reason: String) {
        users += 1
        if token == nil { token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason) }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0, let t = token { ProcessInfo.processInfo.endActivity(t); token = nil }
    }
}

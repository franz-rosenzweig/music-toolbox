import AppKit
import Foundation
import Observation

/// What a kind of device allows and keeps for itself. The server is adding the real device
/// profiles; until its API lands these two are built in, and the limits are optional so that a
/// profile from the server can fill them in.
struct DeviceProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// rsync patterns, anchored to the music folder, that the device owns and a copy must never touch
    var protect: [String] = []
    var formats: [String]?
    var maxSampleRate: Int?
    var maxBitDepth: Int?
    var maxFlacBlockSize: Int?
    var convertTo: String?

    static let h2 = DeviceProfile(id: "hifi-walker-h2", name: "HiFi Walker H2",
                                  protect: ["/.rockbox/", "/settings.txt", "/update.upt", "/*.upt"],
                                  maxFlacBlockSize: 4608)
    static let generic = DeviceProfile(id: "generic", name: "Other")
    static let builtIn = [h2, generic]

    static func named(_ id: String?) -> DeviceProfile { builtIn.first { $0.id == id } ?? .h2 }

    /// The limits worth a label on the device's page.
    var limits: [String] {
        var out: [String] = []
        if let f = formats { out.append(f.map { $0.uppercased() }.joined(separator: " ")) }
        if let r = maxSampleRate { out.append("≤ \(Double(r) / 1000) kHz".replacingOccurrences(of: ".0 ", with: " ")) }
        if let b = maxBitDepth { out.append("≤ \(b)-bit") }
        if let n = maxFlacBlockSize { out.append("FLAC block ≤ \(n)") }
        return out
    }
}

/// `.dap-sync-target`, the file that says "this volume is a device" -- the same file dap-sync-mac.sh
/// writes, so the script and the app agree on which disk is which. Unknown lines are kept.
struct Marker: Hashable, Sendable {
    static let fileName = ".dap-sync-target"

    var musicDir: String
    var profile: String?
    var name: String?
    var extra: [String] = []

    static func read(at volume: URL) -> Marker? {
        guard let text = try? String(contentsOf: volume.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        var m = Marker(musicDir: "")
        var sawMusicDir = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            if l.hasPrefix("musicdir=") { m.musicDir = String(l.dropFirst(9)); sawMusicDir = true }
            else if l.hasPrefix("profile=") { m.profile = String(l.dropFirst(8)) }
            else if l.hasPrefix("name=") { m.name = String(l.dropFirst(5)) }
            else if l.hasPrefix("marked=") || l.hasPrefix("#") { continue }
            else { m.extra.append(l) }
        }
        if !sawMusicDir { m.musicDir = Marker.detectMusicDir(volume) }
        return m
    }

    func write(to volume: URL) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["# dap-sync target marker", "marked=\(f.string(from: Date()))", "musicdir=\(musicDir)"]
        if let profile { lines.append("profile=\(profile)") }
        if let name { lines.append("name=\(name)") }
        lines += extra
        try (lines.joined(separator: "\n") + "\n").write(to: volume.appendingPathComponent(Marker.fileName), atomically: true, encoding: .utf8)
    }

    /// Where the music sits: the volume root when there are music files within two or three levels
    /// of it, else a "Music" folder if there is one.
    static func detectMusicDir(_ volume: URL) -> String {
        let fm = FileManager.default
        let exts: Set<String> = ["flac", "mp3", "m4a"]
        let rootDepth = volume.standardizedFileURL.pathComponents.count
        if let e = fm.enumerator(at: volume, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                let depth = u.standardizedFileURL.pathComponents.count - rootDepth
                if depth > 3 { e.skipDescendants(); continue }
                if depth >= 2, exts.contains(u.pathExtension.lowercased()) { return "" }
            }
        }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: volume.appendingPathComponent("Music").path, isDirectory: &isDir) && isDir.boolValue ? "Music" : ""
    }
}

struct Volume: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var total: Int64
    var free: Int64
    var marker: Marker?
    var id: String { url.path }

    var profile: DeviceProfile { DeviceProfile.named(marker?.profile) }
    var title: String { marker?.name ?? name }
    var music: URL { marker.map { $0.musicDir.isEmpty ? url : url.appendingPathComponent($0.musicDir, isDirectory: true) } ?? url }
    var isDevice: Bool { marker != nil }
}

@Observable @MainActor
final class DeviceStore {
    static let shared = DeviceStore()

    var volumes: [Volume] = []
    var devices: [Volume] { volumes.filter(\.isDevice) }
    var candidates: [Volume] { volumes.filter { !$0.isDevice } }

    private var watching: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            watching.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
        Task { await refresh() }
    }

    func refresh() async {
        volumes = await Task.detached { Self.scan() }.value
    }

    /// Every mounted volume that is not the Mac's own disk. The marker decides which are devices.
    nonisolated static func scan() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let rootDev = (try? FileManager.default.attributesOfFileSystem(forPath: "/"))?[.systemNumber] as? Int
        return urls.compactMap { url in
            guard url.path != "/" else { return nil }
            let dev = (try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemNumber] as? Int
            let v = try? url.resourceValues(forKeys: Set(keys))
            let marker = Marker.read(at: url)
            if marker == nil, dev == rootDev || v?.volumeIsInternal == true { return nil }
            return Volume(url: url, name: v?.volumeName ?? url.lastPathComponent,
                          total: Int64(v?.volumeTotalCapacity ?? 0), free: Int64(v?.volumeAvailableCapacity ?? 0), marker: marker)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setUp(_ volume: Volume, profile: DeviceProfile) async throws {
        let dir = await Task.detached { Marker.detectMusicDir(volume.url) }.value
        try Marker(musicDir: dir, profile: profile.id, name: volume.name).write(to: volume.url)
        await refresh()
    }

    func setProfile(_ volume: Volume, _ profile: DeviceProfile) async throws {
        guard var m = volume.marker else { return }
        m.profile = profile.id
        try m.write(to: volume.url)
        await refresh()
    }

    func eject(_ volume: Volume) async throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        await refresh()
    }
}

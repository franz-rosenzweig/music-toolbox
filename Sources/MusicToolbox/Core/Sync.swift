import Foundation
import Observation

/// rsync, found and driven the way dap-sync-mac.sh drives it.
enum Rsync {
    /// What belongs to the device (or to macOS), never copied over and never deleted by a mirror. The
    /// patterns are never run with --delete-excluded, which is what keeps them safe.
    static let keep = ["/.rockbox/", "/Playlists/", "/*.pdf", "/.dap-sync-target", "/System Volume Information/",
                       "/settings.txt", "/update.upt", "/*.upt", ".Spotlight-V100", ".Trashes", ".fseventsd"]
    /// Junk that sits in the library on the server and should not travel to a device.
    static let junk = ["/Music/", "/Libation/", "/$RECYCLE.BIN/", "/settings.txt", "/update.upt", "/.stignore",
                       ".syncthing.*", ".stfolder", ".stversions", "*.tmp", ".localized"]

    nonisolated(unsafe) private static var found: String??

    /// rsync 3.1 or newer: Homebrew's. Apple's openrsync has neither --info nor --log-file.
    static func locate() async -> String? {
        if let found { return found }
        var candidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"]
        if let e = ProcessInfo.processInfo.environment["MUSIC_RSYNC"] { candidates.insert(e, at: 0) }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            guard let o = try? await Proc.run(c, ["--version"]),
                  let m = o.text.firstMatch(of: #/version (\d+)\.(\d+)/#), let major = Int(m.1), let minor = Int(m.2) else { continue }
            if major > 3 || (major == 3 && minor >= 1) { found = .some(c); return c }
        }
        found = .some(nil)
        return nil
    }

    static func common(_ remote: Remote, _ profile: DeviceProfile) -> [String] {
        ["--modify-window=2", "--no-perms", "--no-owner", "--no-group", "-8", "-s", "-e", remote.sshCommand]
            + (keep + profile.protect + junk).map { "--exclude=\($0)" }
    }

    /// "  1,234,567  45%  12.34MB/s  0:00:12 (xfr#3, to-chk=7/20)"
    static func progress(_ line: String) -> (bytes: Int64, percent: Int)? {
        guard let m = line.firstMatch(of: #/^\s*([\d,]+)\s+(\d+)%/#) else { return nil }
        return (Int64(m.1.replacingOccurrences(of: ",", with: "")) ?? 0, Int(m.2) ?? 0)
    }
}

@Observable @MainActor
final class DeviceSession {
    struct Item: Identifiable, Equatable {
        enum State { case waiting, copying, done, failed }
        var entry: String
        var size: Int64
        var missing: Bool
        var state: State = .waiting
        var id: String { entry }
        private var parts: [Substring] { entry.split(separator: "/") }
        var title: String { parts.last.map(String.init) ?? entry }
        var subtitle: String { parts.dropLast().joined(separator: " · ") }
    }

    struct Summary: Identifiable {
        let id = UUID()
        var mode: Mode
        var result: String
        var copied: Int
        var removed: Int
        var seconds: Int
        var date = Date()
    }

    struct DryRun: Equatable {
        var new = 0, changed = 0, timeOnly = 0
        var junk = 0
        var stale: [String: Int] = [:]
        var staleCount: Int { stale.values.reduce(0, +) }
    }

    enum Mode: String { case queue, all, mirror }
    enum Activity: Equatable { case idle, loading, copying, planning }

    private(set) var volume: Volume
    var items: [Item] = []
    var libraryBytes: Int64?
    var onDevice: Int64?
    var activity: Activity = .idle
    var mode: Mode?
    var fraction: Double?
    var current = ""
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var rate: Double = 0
    var error: String?
    var dryRun: DryRun?
    var dryRunMode: Mode?
    var history: [Summary] = []

    private var task: Task<Void, Never>?
    private var started = Date()

    init(_ volume: Volume) { self.volume = volume }

    var queueBytes: Int64 { items.filter { !$0.missing }.reduce(0) { $0 + $1.size } }
    var busy: Bool { activity != .idle }
    var left: Double? { rate > 0 && bytesTotal > bytesDone ? Double(bytesTotal - bytesDone) / rate : nil }

    func update(_ v: Volume) { volume = v }

    // MARK: reading

    func load() {
        guard activity == .idle else { return }
        start(.loading) { await self.read() }
    }

    private func read() async {
        guard let remote = Config.remote else { error = "Add the SSH address in Settings"; return }
        do {
            let entries = try await remote.queue()
            let sizes = try await remote.sizes(of: entries)
            items = entries.map { e in
                let s = sizes[e] ?? -1
                return Item(entry: e, size: max(0, s), missing: s < 0)
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = Self.describe(error)
        }
        if let used = try? await remote.librarySize() { libraryBytes = used }
        await measure()
    }

    func measure() async {
        let url = volume.music
        onDevice = await Task.detached { Self.directorySize(url) }.value
        await refreshVolume()
    }

    private func refreshVolume() async {
        if let v = DeviceStore.scan().first(where: { $0.url == volume.url }) { volume = v }
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
        return total
    }

    static func describe(_ error: Error) -> String {
        let m = (error as? RemoteError)?.detail ?? error.localizedDescription
        if m.contains("Permission denied") { return "The key was refused" }
        if m.contains("timed out") || m.contains("No route") || m.contains("refused") || m.contains("Could not resolve") { return "Can’t reach the server" }
        return m.split(separator: "\n").first.map(String.init) ?? m
    }

    // MARK: running

    func copyQueue() { begin(.queue) { try await self.runQueue() } }
    func copyEverything() { begin(.all) { try await self.runWhole(.all, delete: false) } }
    func mirror() { begin(.mirror) { try await self.runWhole(.mirror, delete: true) } }
    func cancel() { task?.cancel() }

    func removeFromQueue(_ item: Item) {
        guard let remote = Config.remote else { return }
        Task {
            try? await remote.complete([item.entry])
            items.removeAll { $0.entry == item.entry }
        }
    }

    private func start(_ a: Activity, _ work: @escaping () async -> Void) {
        activity = a
        task = Task {
            await work()
            self.activity = .idle
            self.task = nil
        }
    }

    private func begin(_ m: Mode, _ work: @escaping () async throws -> Void) {
        guard activity == .idle else { return }
        dryRun = nil
        error = nil
        mode = m
        fraction = nil
        current = ""
        bytesDone = 0
        bytesTotal = 0
        rate = 0
        started = Date()
        Awake.shared.hold("Copying music to a device")
        start(.copying) {
            do { try await work() } catch is CancellationError {} catch { self.error = Self.describe(error) }
            Awake.shared.release()
            self.mode = nil
            self.fraction = nil
            await self.refreshVolume()
        }
    }

    private func tools() async throws -> (Remote, String) {
        guard let remote = Config.remote else { throw RemoteError("Add the SSH address in Settings") }
        guard let rsync = await Rsync.locate() else { throw RemoteError("rsync 3.1 or newer is missing") }
        try await remote.check(rsync: rsync)
        return (remote, rsync)
    }

    private func ensureSpace(_ need: Int64) async throws {
        await refreshVolume()
        var room = volume.free
        if need > room {
            let used = await Task.detached { [url = volume.music] in Self.directorySize(url) }.value
            onDevice = used
            room += used
            if need > room { throw RemoteError("Needs \(Fmt.size(need)) · \(Fmt.size(volume.free)) free") }
        }
    }

    private func mkdirs(_ url: URL) async {
        await Task.detached { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }.value
    }

    private func line(_ text: String, base: Int64, whole: Bool) {
        guard let p = Rsync.progress(text) else {
            if !text.hasPrefix("sending") && !text.hasPrefix("sent ") && !text.hasPrefix("total ") && !text.contains("[") { current = (text as NSString).lastPathComponent }
            return
        }
        if whole { fraction = Double(p.percent) / 100; bytesDone = p.bytes } else {
            bytesDone = base + p.bytes
            fraction = bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil
        }
        let t = Date().timeIntervalSince(started)
        if t > 1 { rate = Double(bytesDone) / t }
    }

    private func runQueue() async throws {
        let todo = items.filter { !$0.missing }
        guard !todo.isEmpty else { return }
        let (remote, rsync) = try await tools()
        try await ensureSpace(queueBytes)
        bytesTotal = queueBytes
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mt-run-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        var copied: [String] = [], failed: [String] = [], base: Int64 = 0
        var result = "finished"
        do {
            for item in todo {
                try Task.checkCancellation()
                mark(item, .copying)
                current = item.title
                let (status, why) = try await copy(item.entry, remote: remote, rsync: rsync, log: log, base: base)
                if status == 0 || status == 24 { copied.append(item.entry); mark(item, .done); base += item.size }
                else { failed.append(item.entry + (why.isEmpty ? "" : " (\(why))")); mark(item, .failed) }
            }
            if !failed.isEmpty { result = "failed" }
        } catch is CancellationError {
            result = "cancelled"
        }
        await Task { await self.finish(.queue, result, copied: copied, remote: remote, log: log,
                                       detail: failed.isEmpty ? "\(todo.count) queued item(s)" : "\(failed.count) of \(todo.count) failed: \(failed.joined(separator: "; "))") }.value
        if failed.isEmpty, result == "finished" { fraction = 1 }
        if !failed.isEmpty { error = failed.count == 1 ? failed[0] : "\(failed.count) did not copy" }
    }

    private func mark(_ item: Item, _ s: Item.State) {
        if let i = items.firstIndex(where: { $0.entry == item.entry }) { items[i].state = s }
    }

    /// One queue entry (an album folder, or a single track). The name goes to rsync on stdin, not in
    /// its arguments: Foundation turns an argument like "fhána" into decomposed Unicode, and the
    /// server has the composed one.
    private func copy(_ entry: String, remote: Remote, rsync: String, log: URL, base: Int64) async throws -> (Int32, String) {
        var args = ["-rt", "--files-from=-", "--partial", "--info=name1,progress2", "--log-file=\(log.path)", "--log-file-format=%i %n"]
        args += Rsync.common(remote, volume.profile)
        await mkdirs(volume.music)
        args += ["\(remote.target):\(remote.musicPath)/", volume.music.path + "/"]
        let split = LineSplitter()
        let o = try await Proc.run(rsync, args, input: Data((entry + "\n").utf8)) { data in
            let lines = split.feed(data)
            Task { @MainActor in for l in lines { self.line(l, base: base, whole: false) } }
        }
        try Task.checkCancellation()
        return (o.status, o.status == 0 ? "" : String(o.errText.split(separator: "\n").first ?? "rsync exit \(o.status)"))
    }

    private func runWhole(_ m: Mode, delete: Bool) async throws {
        let (remote, rsync) = try await tools()
        let need = try await remote.librarySize()
        libraryBytes = need
        try await ensureSpace(need)
        let queued = (try? await remote.queue()) ?? []
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mt-run-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        var args = ["-rt", "--partial", "--no-inc-recursive", "--info=name1,progress2", "--log-file=\(log.path)", "--log-file-format=%i %n"]
        if delete { args.append("--delete") }
        args += Rsync.common(remote, volume.profile)
        await mkdirs(volume.music)
        args += ["\(remote.target):\(remote.musicPath)/", volume.music.path + "/"]
        let split = LineSplitter()
        bytesTotal = need
        var result = "finished", detail = "full library"
        do {
            let o = try await Proc.run(rsync, args) { data in
                let lines = split.feed(data)
                Task { @MainActor in for l in lines { self.line(l, base: 0, whole: true) } }
            }
            try Task.checkCancellation()
            if o.status != 0 && o.status != 24 { result = "failed"; detail = "rsync exit \(o.status)"; error = "The copy stopped" }
        } catch is CancellationError {
            result = "cancelled"
        }
        await Task { await self.finish(m, result, copied: result == "finished" ? queued : [], remote: remote, log: log, detail: detail) }.value
        if result == "finished" { fraction = 1; await read() }
    }

    /// Clears macOS's ._ twins (exFAT keeps xattrs as files), takes the copied entries off the queue
    /// and tells the panel. Runs even when the copy was cancelled, so what did copy is not copied again.
    private func finish(_ m: Mode, _ result: String, copied: [String], remote: Remote, log: URL, detail: String) async {
        _ = try? await Proc.run("/usr/bin/dot_clean", ["-m", volume.url.path])
        try? await remote.complete(copied)
        let text = (try? Data(contentsOf: log)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let lines = text.split(separator: "\n")
        let n = lines.filter { $0.contains(" >f") }.count
        // music only: macOS's ._ twins and .DS_Store come and go with every write
        let removed = lines.filter { l in
            guard let r = l.range(of: "*deleting") else { return false }
            let path = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return !path.hasSuffix("/") && !path.split(separator: "/").contains { $0.hasPrefix("._") || $0 == ".DS_Store" }
        }.count
        let secs = Int(Date().timeIntervalSince(started))
        history.insert(Summary(mode: m, result: result, copied: n, removed: removed, seconds: secs), at: 0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let row: [String: Any] = ["ts": f.string(from: Date()), "mode": m.rawValue, "result": result, "copied": n, "removed": removed,
                                  "seconds": secs, "mac": ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "",
                                  "rsync": "3", "app": "music-toolbox", "detail": String(detail.prefix(300))]
        if let d = try? JSONSerialization.data(withJSONObject: row, options: [.withoutEscapingSlashes]) {
            await remote.report(String(decoding: d, as: UTF8.self))
        }
        if m == .queue || result == "finished" { items.removeAll { copied.contains($0.entry) } }
    }

    // MARK: looking before copying

    func check() { look(.all) }
    func planMirror() { look(.mirror) }
    func dismissPlan() { dryRun = nil }

    private func look(_ m: Mode) {
        guard activity == .idle else { return }
        error = nil
        dryRun = nil
        start(.planning) {
            do {
                let (remote, rsync) = try await self.tools()
                var args = ["-rti", "--dry-run"]
                if m == .mirror { args.append("--delete") }
                args += Rsync.common(remote, self.volume.profile)
                await self.mkdirs(self.volume.music)
                args += ["\(remote.target):\(remote.musicPath)/", self.volume.music.path + "/"]
                let o = try await Proc.run(rsync, args)
                guard o.status == 0 || o.status == 24 else { throw RemoteError(o.errText) }
                self.dryRun = Self.parse(o.text)
                self.dryRunMode = m
            } catch is CancellationError {} catch { self.error = Self.describe(error) }
        }
    }

    /// rsync's itemized dry run: ">f+++++++++ path" is new, ">f..t......" only the time differs,
    /// "*deleting path" would go. macOS's ._ files and .DS_Store come back on every write and are
    /// counted apart from music.
    nonisolated static func parse(_ text: String) -> DryRun {
        var r = DryRun()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("*deleting") {
                let path = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                if path.hasSuffix("/") { continue }
                if path.split(separator: "/").contains(where: { $0.hasPrefix("._") || $0 == ".DS_Store" }) { r.junk += 1 }
                else { r.stale[String(path.split(separator: "/").first ?? ""), default: 0] += 1 }
            } else if line.hasPrefix(">f") {
                let code = line.prefix(11)
                if code.contains("+") { r.new += 1 } else if code == ">f..t......" { r.timeOnly += 1 } else { r.changed += 1 }
            }
        }
        return r
    }

    func confirmMirror() {
        dryRun = nil
        mirror()
    }

    /// Clears the ._ twins once more first: they are what a player's database would trip over.
    func eject() async {
        _ = try? await Proc.run("/usr/bin/dot_clean", ["-m", volume.url.path])
        do { try await DeviceStore.shared.eject(volume) } catch { self.error = "Couldn’t eject" }
    }
}

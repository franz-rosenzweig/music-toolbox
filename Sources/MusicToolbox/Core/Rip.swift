import AppKit
import CryptoKit
import Foundation
import Observation

/// An audio CD in the drive, as macOS shows it: a volume of "N Audio Track.aiff" files and a
/// ".TOC.plist" with the disc's table of contents.
struct Disc: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        var number: Int
        var file: URL
        var bytes: Int64
        var start: Int
        var frames: Int
        var seconds: Double { Double(frames) / 75 }
        /// samples at 44.1 kHz, which a correct rip has exactly
        var samples: Int64 { Int64(frames) * 588 }
    }

    var volume: URL
    var first: Int
    var last: Int
    var leadout: Int
    var tracks: [Track]
    var id: String

    var toc: String { "\(first)+\(last)+\(leadout)+" + tracks.map { String($0.start) }.joined(separator: "+") }
    var totalSeconds: Double { Double(leadout - (tracks.first?.start ?? 150)) / 75 }

    /// MusicBrainz's disc ID: SHA-1 of the first and last track and 100 offsets (the lead-out, then each
    /// track), in hex, as base 64 with . _ - for + / =.
    static func discID(first: Int, last: Int, leadout: Int, starts: [Int: Int]) -> String {
        var sha = Insecure.SHA1()
        func hex(_ n: Int, _ width: Int) -> Data { Data(String(format: "%0\(width)X", n).utf8) }
        sha.update(data: hex(first, 2))
        sha.update(data: hex(last, 2))
        sha.update(data: hex(leadout, 8))
        for i in 1...99 { sha.update(data: hex(starts[i] ?? 0, 8)) }
        return Data(sha.finalize()).base64EncodedString().replacingOccurrences(of: "+", with: ".").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "-")
    }

    /// Reads the disc's table of contents. `files` is where the track files are (the volume, normally).
    static func parse(toc: Data, volume: URL, files: [Int: (URL, Int64)]) -> Disc? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: toc, format: nil)) as? [String: Any],
              let session = (plist["Sessions"] as? [[String: Any]])?.first,
              let first = session["First Track"] as? Int, let last = session["Last Track"] as? Int, let leadout = session["Leadout Block"] as? Int,
              let array = session["Track Array"] as? [[String: Any]] else { return nil }
        var starts: [Int: Int] = [:]
        var audio: [Int] = []
        for t in array {
            guard let n = t["Point"] as? Int, let s = t["Start Block"] as? Int else { continue }
            starts[n] = s
            if (t["Data"] as? Bool) != true { audio.append(n) }
        }
        let order = starts.keys.sorted()
        var tracks: [Track] = []
        for n in audio.sorted() {
            guard let s = starts[n], let f = files[n] else { continue }
            let next = order.first { $0 > n }.flatMap { starts[$0] } ?? leadout
            tracks.append(Track(number: n, file: f.0, bytes: f.1, start: s, frames: next - s))
        }
        guard !tracks.isEmpty else { return nil }
        return Disc(volume: volume, first: first, last: last, leadout: leadout, tracks: tracks, id: discID(first: first, last: last, leadout: leadout, starts: starts))
    }

    /// The audio CD among the mounted volumes, if there is one.
    static func find() -> Disc? {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in urls {
            guard let toc = try? Data(contentsOf: v.appendingPathComponent(".TOC.plist")) else { continue }
            var files: [Int: (URL, Int64)] = [:]
            for f in (try? FileManager.default.contentsOfDirectory(at: v, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.pathExtension.lowercased() == "aiff" {
                if let n = Int(f.lastPathComponent.split(separator: " ").first ?? "") { files[n] = (f, Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }
            }
            if let d = parse(toc: toc, volume: v, files: files) { return d }
        }
        return nil
    }
}

/// A release MusicBrainz says this disc is.
struct MBRelease: Identifiable, Hashable, Sendable {
    struct Track: Hashable, Sendable {
        var number: Int
        var title: String
        var artist: String
        var artistIDs: [String]
        var recordingID: String?
        var trackID: String?
        var length: Int?
    }

    var id: String
    var title: String
    var artist: String
    var artistIDs: [String]
    var date: String?
    var country: String?
    var label: String?
    var catalog: String?
    var barcode: String?
    var releaseGroupID: String?
    var hasCover: Bool
    var medium: Int
    var media: Int
    var tracks: [Track]

    var year: String { String((date ?? "").prefix(4)) }
    var summary: String { [title, country, date.map { String($0.prefix(4)) }, "\(tracks.count) tracks"].compactMap { $0 }.joined(separator: " · ") }
}

enum MusicBrainz {
    static var userAgent: String { "MusicToolbox/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") ( https://github.com/franz-rosenzweig/music-toolbox )" }

    static func parse(_ data: Data, discID: String, trackCount: Int) -> [MBRelease] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let releases = root["releases"] as? [[String: Any]] else { return [] }
        func credit(_ any: Any?) -> (String, [String]) {
            guard let c = any as? [[String: Any]] else { return ("", []) }
            let name = c.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
            return (name, c.compactMap { ($0["artist"] as? [String: Any])?["id"] as? String })
        }
        return releases.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String, let media = r["media"] as? [[String: Any]] else { return nil }
            // the medium this disc is: the one that lists its ID, else the first with the same number of tracks
            let index = media.firstIndex { ($0["discs"] as? [[String: Any]])?.contains { $0["id"] as? String == discID } == true }
                ?? media.firstIndex { ($0["track-count"] as? Int) == trackCount } ?? 0
            let m = media[index]
            let tracks: [MBRelease.Track] = (m["tracks"] as? [[String: Any]] ?? []).enumerated().map { i, t in
                let rec = t["recording"] as? [String: Any]
                let (artist, ids) = credit(t["artist-credit"] ?? rec?["artist-credit"])
                return MBRelease.Track(number: Int(t["position"] as? Int ?? Int(t["number"] as? String ?? "") ?? i + 1), title: t["title"] as? String ?? rec?["title"] as? String ?? "Track \(i + 1)",
                                       artist: artist, artistIDs: ids, recordingID: rec?["id"] as? String, trackID: t["id"] as? String, length: t["length"] as? Int ?? rec?["length"] as? Int)
            }
            let (artist, ids) = credit(r["artist-credit"])
            let label = ((r["label-info"] as? [[String: Any]])?.first?["label"] as? [String: Any])?["name"] as? String
            let catalog = (r["label-info"] as? [[String: Any]])?.first?["catalog-number"] as? String
            let cover = (r["cover-art-archive"] as? [String: Any])?["front"] as? Bool ?? false
            return MBRelease(id: id, title: title, artist: artist, artistIDs: ids, date: r["date"] as? String, country: r["country"] as? String,
                             label: label == "[no label]" ? nil : label, catalog: catalog, barcode: r["barcode"] as? String,
                             releaseGroupID: (r["release-group"] as? [String: Any])?["id"] as? String, hasCover: cover, medium: index + 1, media: media.count, tracks: tracks)
        }
    }

    /// The releases with this disc ID; when there are none, the ones whose track lengths are close to this disc's.
    /// MusicBrainz asks for one request a second and answers 503 when it is busy, so a busy answer is asked again.
    static func lookup(_ disc: Disc) async throws -> [MBRelease] {
        let inc = "artist-credits+recordings+release-groups+labels"
        for (id, extra) in [(disc.id, ""), ("-", "&toc=\(disc.toc)&cdstubs=no")] {
            var req = URLRequest(url: URL(string: "https://musicbrainz.org/ws/2/discid/\(id)?inc=\(inc)&fmt=json\(extra)")!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 25
            var data = Data()
            var status = 0
            for attempt in 0..<4 {
                if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
                let (d, resp) = try await URLSession.shared.data(for: req)
                data = d
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status != 503 && status != 429 { break }
            }
            if status == 404 { continue }
            guard status == 200 else { throw RemoteError("MusicBrainz answered \(status)") }
            let r = parse(data, discID: disc.id, trackCount: disc.tracks.count)
            if !r.isEmpty { return r }
        }
        return []
    }

    static func cover(_ release: String) async -> Data? {
        for size in ["front-1200", "front"] {
            var req = URLRequest(url: URL(string: "https://coverartarchive.org/release/\(release)/\(size)")!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 25
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil { return data }
        }
        return nil
    }
}

/// Ripping an audio CD to FLAC, tagged from MusicBrainz, then on to the upload.
@Observable @MainActor
final class Ripper {
    static let shared = Ripper()

    struct Item: Identifiable, Equatable {
        enum State: Equatable { case waiting, ripping, done, failed(String) }
        var track: Disc.Track
        var title: String
        var artist: String
        var state: State = .waiting
        var id: Int { track.number }
    }

    enum Activity: Equatable { case idle, looking, ripping, uploaded }

    var disc: Disc?
    var releases: [MBRelease] = []
    var chosen = 0
    var albumArtist = ""
    var album = ""
    var year = ""
    var items: [Item] = []
    var cover: Data?
    var activity: Activity = .idle
    var error: String?
    var folder: URL?
    var done = 0
    var upload = true

    private var task: Task<Void, Never>?
    private var looked: String?
    private var observers: [NSObjectProtocol] = []

    static var root: URL {
        let saved = (UserDefaults.standard.string(forKey: "ripsFolder") ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("CD Rips", isDirectory: true)
    }

    static func flac() -> String? {
        let env = ProcessInfo.processInfo.environment["MUSIC_FLAC"]
        return ([env].compactMap { $0 } + ["/opt/homebrew/bin/flac", "/usr/local/bin/flac"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func metaflac() -> String? {
        ["/opt/homebrew/bin/metaflac", "/usr/local/bin/metaflac"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var fraction: Double {
        let total = items.reduce(0) { $0 + $1.track.bytes }
        guard total > 0 else { return 0 }
        return Double(items.filter { if case .done = $0.state { true } else { false } }.reduce(0) { $0 + $1.track.bytes }) / Double(total)
    }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.scan() } })
        }
        Task { await scan() }
    }

    /// Looks for a disc, and asks MusicBrainz about a new one.
    /// Set by the self-test to show a disc that is not in the drive.
    var frozen = false
    private var started = false

    func scan() async {
        guard activity != .ripping, !frozen else { return }
        let d = await Task.detached { Disc.find() }.value
        guard d?.id != disc?.id || d == nil else { started = true; return }
        disc = d
        releases = []
        items = []
        cover = nil
        error = nil
        activity = .idle
        guard let d else { looked = nil; started = true; return }
        // a disc that has just been put in (not one already there when the app started)
        if started, Prefs.openForDiscs { Nav.shared.arrive(.rip) }
        started = true
        items = d.tracks.map { Item(track: $0, title: "Track \($0.number)", artist: "") }
        looked = d.id
        await lookup()
    }

    func lookup() async {
        guard let d = disc else { return }
        activity = .looking
        defer { activity = .idle }
        do {
            releases = try await MusicBrainz.lookup(d)
            if releases.isEmpty { error = "Not on MusicBrainz"; return }
            error = nil
            await choose(0)
        } catch { self.error = "Can’t reach MusicBrainz" }
    }

    func choose(_ i: Int) async {
        guard releases.indices.contains(i), let d = disc else { return }
        chosen = i
        let r = releases[i]
        albumArtist = r.artist
        album = r.title
        year = r.year
        items = d.tracks.map { t in
            let mb = r.tracks.first { $0.number == t.number } ?? (r.tracks.indices.contains(t.number - 1) ? r.tracks[t.number - 1] : nil)
            return Item(track: t, title: mb?.title ?? "Track \(t.number)", artist: mb?.artist ?? r.artist)
        }
        cover = nil
        await refreshRipped()
        if r.hasCover { cover = await MusicBrainz.cover(r.id) }
    }

    var release: MBRelease? { releases.indices.contains(chosen) ? releases[chosen] : nil }

    // MARK: ripping

    func rip(andUpload: Bool) {
        guard activity == .idle, disc != nil else { return }
        upload = andUpload
        error = nil
        activity = .ripping
        done = 0
        Awake.shared.hold("Ripping a CD")
        task = Task {
            do { try await self.run() } catch is CancellationError { self.error = "Cancelled" } catch { self.error = (error as? RemoteError)?.detail ?? error.localizedDescription }
            Awake.shared.release()
            if self.activity == .ripping { self.activity = .idle }
            self.task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Sends the album's whole folder (every disc in it) to the server.
    func uploadFolder() {
        guard let dir = folder ?? destination else { return }
        Task {
            let up = UploadStore.shared
            await up.add([dir])
            up.upload()
            Nav.shared.place = .upload
        }
    }

    static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return t.isEmpty ? "Untitled" : String(t.prefix(120))
    }

    /// Where this disc's files go: every disc of a set shares the album's folder, so one upload takes them all.
    var destination: URL? {
        guard let disc else { return nil }
        let artist = albumArtist.trimmingCharacters(in: .whitespaces), album = self.album.trimmingCharacters(in: .whitespaces)
        return Self.root.appendingPathComponent(Self.clean(artist.isEmpty ? "Unknown Artist" : artist), isDirectory: true)
            .appendingPathComponent(Self.clean(album.isEmpty ? "Disc \(disc.id.prefix(8))" : album), isDirectory: true)
    }

    /// Which discs of this album are already in its folder, read from their DISCNUMBER tags.
    var rippedDiscs: [Int] = []

    func refreshRipped() async {
        guard let dir = destination, let metaflac = Self.metaflac() else { rippedDiscs = []; return }
        let found = await Task.detached { () -> [Int] in
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "flac" }
            var discs = Set<Int>()
            for f in files {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: metaflac)
                p.arguments = ["--show-tag=DISCNUMBER", f.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                try? p.run()
                p.waitUntilExit()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if let n = Int(out.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { discs.insert(n) }
            }
            return discs.sorted()
        }.value
        rippedDiscs = found
    }

    var discNumber: Int { release?.medium ?? 1 }
    var discCount: Int { release?.media ?? 1 }
    /// Discs of this set that are not in the folder yet (this one counts as being ripped now).
    var missingDiscs: [Int] { discCount > 1 ? (1...discCount).filter { $0 != discNumber && !rippedDiscs.contains($0) } : [] }

    private func run() async throws {
        guard let disc, let flac = Self.flac() else { throw RemoteError("flac is missing (brew install flac)") }
        guard let metaflac = Self.metaflac() else { throw RemoteError("metaflac is missing (brew install flac)") }
        let artist = albumArtist.trimmingCharacters(in: .whitespaces), album = self.album.trimmingCharacters(in: .whitespaces)
        guard let dir = destination else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mt-rip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var picture: String?
        if let cover {
            let p = scratch.appendingPathComponent("cover.jpg")
            try cover.write(to: p)
            try cover.write(to: dir.appendingPathComponent("cover.jpg"))
            picture = p.path
        }
        let r = release
        for i in items.indices {
            try Task.checkCancellation()
            items[i].state = .ripping
            let it = items[i]
            let tmp = scratch.appendingPathComponent(String(format: "%02d.flac", it.track.number))
            // the track as macOS reads it from the disc, copied off in large blocks (an encoder reading the
            // disc in small pieces gets a tenth of the speed), then encoded and checked against what was read
            let aiff = scratch.appendingPathComponent(String(format: "%02d.aiff", it.track.number))
            try await Self.copy(it.track.file, to: aiff, expected: it.track.bytes)
            let enc = try await Proc.run(flac, ["-8", "--verify", "--silent", "-f", "-o", tmp.path, aiff.path])
            try? FileManager.default.removeItem(at: aiff)
            try Task.checkCancellation()
            guard enc.status == 0 else { items[i].state = .failed("flac"); throw RemoteError("Track \(it.track.number): \(enc.errText.split(separator: "\n").first.map(String.init) ?? "flac failed")") }
            // tags go in on stdin, as UTF-8 bytes: an accent in an argument would be decomposed by Foundation
            var tags: [(String, String)] = [("TITLE", it.title), ("ARTIST", it.artist.isEmpty ? artist : it.artist), ("ALBUM", album), ("ALBUMARTIST", artist),
                                            ("TRACKNUMBER", String(it.track.number)), ("TRACKTOTAL", String(disc.tracks.count)), ("DISCID", disc.id)]
            if !year.isEmpty { tags.append(("DATE", r?.date ?? year)) }
            if let r {
                tags += [("DISCNUMBER", String(r.medium)), ("MUSICBRAINZ_ALBUMID", r.id)]
                if r.media > 1 { tags.append(("DISCTOTAL", String(r.media))) }
                if let g = r.releaseGroupID { tags.append(("MUSICBRAINZ_RELEASEGROUPID", g)) }
                if let l = r.label { tags.append(("LABEL", l)) }
                if let c = r.catalog { tags.append(("CATALOGNUMBER", c)) }
                if let b = r.barcode, !b.isEmpty { tags.append(("BARCODE", b)) }
                if let c = r.country { tags.append(("RELEASECOUNTRY", c)) }
                for id in r.artistIDs { tags.append(("MUSICBRAINZ_ALBUMARTISTID", id)) }
                if let mb = r.tracks.first(where: { $0.number == it.track.number }) {
                    if let id = mb.recordingID { tags.append(("MUSICBRAINZ_TRACKID", id)) }
                    if let id = mb.trackID { tags.append(("MUSICBRAINZ_RELEASETRACKID", id)) }
                    for id in mb.artistIDs { tags.append(("MUSICBRAINZ_ARTISTID", id)) }
                }
            }
            var args = ["--no-utf8-convert", "--import-tags-from=-"]
            if let picture { args.append("--import-picture-from=\(picture)") }
            args.append(tmp.path)
            let t = try await Proc.run(metaflac, args, input: Data(tags.map { "\($0.0)=\($0.1.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n").utf8))
            guard t.status == 0 else { items[i].state = .failed("tags"); throw RemoteError("Track \(it.track.number): \(t.errText.split(separator: "\n").first.map(String.init) ?? "tagging failed")") }
            let prefix = (r?.media ?? 1) > 1 ? "\(r?.medium ?? 1)-" : ""
            let final = dir.appendingPathComponent(String(format: "%@%02d %@.flac", prefix, it.track.number, Self.clean(it.title)))
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: tmp, to: final)
            items[i].state = .done
            done += 1
        }
        await refreshRipped()
        let eject = UserDefaults.standard.object(forKey: "ejectWhenDone") as? Bool ?? true
        if upload {
            let up = UploadStore.shared
            await up.add([dir])
            up.upload()
            activity = .uploaded
            Nav.shared.place = .upload
        } else {
            activity = .idle
        }
        // nothing reads the disc any more: let it out, so the drive's own button is not needed
        if eject {
            let saved = dir
            await self.eject()
            Nav.shared.notify("Ripped to \((saved.path as NSString).abbreviatingWithTildeInPath) · disc ejected")
        }
    }

    /// Reads a file in 4 MB blocks into another, so a disc's drive reads at its own speed. Stops when the task is cancelled.
    nonisolated static func copy(_ from: URL, to: URL, expected: Int64) async throws {
        let work = Task.detached {
            let src = try FileHandle(forReadingFrom: from)
            defer { try? src.close() }
            FileManager.default.createFile(atPath: to.path, contents: nil)
            let dst = try FileHandle(forWritingTo: to)
            defer { try? dst.close() }
            var total: Int64 = 0
            while let chunk = try src.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try dst.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            guard expected == 0 || total == expected else { throw RemoteError("The disc gave \(total) of \(expected) bytes") }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func eject() async {
        guard let v = disc?.volume else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch { self.error = "Couldn’t eject" }
        await scan()
    }
}

import Foundation
import Observation

extension Api {
    struct JobRef: Decodable, Sendable { var job: Int }

    struct Need: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var group: String
        var kind: String
        var title: String
        var sub: String
        var age: Double?
        var later: Bool
        var open: Bool
        var cover: String?
        var fix: String?

        /// imp-<fid>-<gid>
        var importIDs: (fid: String, gid: String)? {
            guard kind == "import" else { return nil }
            let p = id.split(separator: "-", maxSplits: 2).map(String.init)
            return p.count == 3 ? (p[1], p[2]) : nil
        }
    }

    struct NameRef: Decodable, Hashable, Sendable {
        var kind: String
        var name: String
        var suggest: String?
    }

    struct InboxTrack: Decodable, Hashable, Sendable {
        var n: Int?
        var title: String
        var duration: Double?
        var file: String
    }

    struct InboxAlbum: Decodable, Sendable {
        var id: String
        var fid: String
        var gid: String
        var folder: String?
        var artist: String?
        var album: String?
        var year: Int?
        var state: String
        var ageMinutes: Int?
        var nTracks: Int
        var bytes: Int64?
        var duration: Double?
        var format: String?
        var tracks: [InboxTrack]
        var art: String?
        var needsAsis: [NameRef]
        var target: String?
    }

    struct CandidateTrack: Decodable, Hashable, Sendable {
        var index: Int?
        var medium: Int?
        var file: String?
        var title: String?
        var newTitle: String?
        var matched: Bool?
        var length: Double?
        var newLength: Double?
    }

    struct Missing: Decodable, Hashable, Sendable {
        var title: String?
        var index: Int?
        var medium: Int?
    }

    struct Penalty: Decodable, Hashable, Sendable {
        var name: String
        var value: Flex?
    }

    struct Candidate: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var score: Double
        var quality: String
        var artist: String?
        var album: String?
        var year: Int?
        var country: String?
        var media: String?
        var label: String?
        var disambig: String?
        var url: String?
        var tracksTotal: Int?
        var matched: Int?
        var ofFiles: Int?
        var titlesChange: Int?
        var tracks: [CandidateTrack]?
        var missing: [Missing]?
        var extra: [String]?
        var penalties: [Penalty]?
        var needs: [NameRef]?

        var heading: String { [artist, album].compactMap { $0 }.joined(separator: " — ") }
        var detail: String { [year.map(String.init), country, media, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    struct Candidates: Decodable, Sendable {
        var job: Int?
        var status: String
        var error: String?
        var recommendation: String?
        var candidates: [Candidate]?
        var running: Bool { status == "queued" || status == "running" }
    }

    struct AsIs: Decodable, Sendable {
        var job: Int
        var folder: String?
        var queuedForDap: Bool?
    }

    struct NameNeed: Decodable, Identifiable, Hashable, Sendable {
        var kind: String
        var name: String
        var suggest: String?
        var why: String?
        var known: Bool?
        var albums: [AlbumRef]?
        var folders: [String]?
        var id: String { kind + "|" + name }

        struct AlbumRef: Decodable, Hashable, Sendable { var id: String; var title: String; var artist: String? }
    }
}

/// What waits for a decision, as the panel's Needs you page lists it.
@Observable @MainActor
final class NeedsStore {
    static let shared = NeedsStore()

    var items: [Api.Need] = []
    var error: String?
    var loaded = false

    var open: Int { items.filter { $0.open && !$0.later }.count }

    func load() async {
        guard let panel = Config.panel else { return }
        do { items = try await panel.needs(); error = nil } catch is CancellationError {} catch { self.error = DeviceSession.describe(error) }
        loaded = true
    }

    func later(_ n: Api.Need) async {
        let on = !n.later
        try? await Config.panel?.later(n.id, on)
        await load()
        if on { Nav.shared.notify("Put off for a day") { [self] in try? await Config.panel?.later(n.id, false); await load() } }
    }
}

/// Follows one panel job until it ends.
@Observable @MainActor
final class JobFollower {
    var job: Api.Job?
    var error: String?
    private var task: Task<Void, Never>?

    var running: Bool { job?.running ?? false }
    var active: Bool { task != nil }

    func follow(_ id: Int, onDone: (@MainActor (Api.Job) -> Void)? = nil) {
        task?.cancel()
        job = nil
        error = nil
        task = Task {
            guard let panel = Config.panel else { return }
            do {
                var j = try await panel.job(id)
                job = j
                while j.running {
                    try await Task.sleep(for: .seconds(1))
                    j = try await panel.job(id)
                    job = j
                }
                onDone?(j)
            } catch is CancellationError {} catch { self.error = DeviceSession.describe(error) }
            task = nil
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// "Imported Yoavi — Mud memory · 7 tracks": one line per album of an import job.
    var lines: [String] {
        if let l = job?.result["lines"] as? [String] { return l }
        if let r = job?.result, let kind = job?.kind, kind.hasPrefix("lyrics"), let k = r["action"] as? String {
            if k == "remove" { return ["Lyrics removed"] }
            return ["Lyrics saved as \(r["kind"] as? String ?? "text")"]
        }
        if let n = job?.result["found"] as? NSNumber, job?.kind.contains("lookup") == true { return ["Found \(n) lyrics files"] }
        if let summary = job?.result["summary"] as? String { return [summary] }
        if let size = job?.result["size"] as? [Any], size.count == 2, job?.kind == "cover" { return ["Cover saved · \(size[0])×\(size[1])"] }
        guard let a = job?.result["albums"] as? [[String: Any]] else { return [] }
        return a.map { al in
            let status = al["status"] as? String ?? ""
            let name = [al["artist"] as? String, al["album"] as? String].compactMap { $0 }.joined(separator: " — ")
            let n = (al["tracks"] as? NSNumber)?.intValue
            switch status {
            case "imported", "imported-with-differences": return "Imported \(name)" + (n.map { " · \($0) tracks" } ?? "")
            case "skipped": return "Skipped \(name)"
            case "needs-name": return "\(name) needs an English name"
            default: return (al["detail"] as? String) ?? status
            }
        }
    }
}

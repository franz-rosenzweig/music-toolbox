import Foundation

/// History, lyrics, covers, library health, and the device's copy history: the rest of what the
/// panel's web page does (docs/api.md in its repository).
extension Api {
    struct Run: Decodable, Identifiable, Hashable, Sendable {
        var run: String
        var title: String
        var summary: String?
        var reason: String?
        var when: String
        var day: String?
        var who: String
        var kind: String
        var kinds: [String]?
        var files: Int?
        var fields: Int?
        var created: Int?
        var replaced: Int?
        var albums: [String]?
        var nAlbums: Int?
        var canUndo: Bool
        var undone: Bool
        var undoneBy: String?
        var isUndo: Bool
        var undoes: String?
        var external: Bool
        var id: String { run }

        /// "17:45" from the panel's local ISO time
        var time: String { when.count >= 16 ? String(when.dropFirst(11).prefix(5)) : when }
    }

    struct History: Decodable, Sendable {
        var runs: [Run]
        var total: Int
        var next: String?
    }

    struct ChangeRow: Decodable, Hashable, Sendable {
        var field: String
        var before: Flex?
        var after: Flex?
    }

    struct FileChange: Decodable, Hashable, Sendable {
        var path: String
        var rows: [ChangeRow]
    }

    struct RunDetail: Decodable, Sendable {
        var run: String
        var title: String?
        var changes: [FileChange]
        var total: Int
        var offset: Int
        var nextOffset: Int?
    }

    struct UndoPreview: Decodable, Sendable {
        var canUndo: Bool
        var reason: String?
        var musicFilesDeleted: Int?
        var safe: Bool?
        var tags: [String: Int]?
        var createdFiles: [String: Int]?
        var removedFiles: [String: Int]?
        var replacedFiles: [String: Int]?
        var laterRuns: [Later]?
        var conflicts: [Conflict]?
        var note: String?

        struct Later: Decodable, Hashable, Sendable { var run: String; var first: String?; var sharedFiles: Int? }
        struct Conflict: Decodable, Hashable, Sendable { var path: String; var field: String; var runSet: Flex?; var now: Flex?; var wouldRestore: Flex? }

        /// What an undo would do, as short labels.
        var labels: [String] {
            var out: [String] = []
            if let n = tags?["to_restore"], n > 0 { out.append("\(n) tag values back") }
            if let n = createdFiles?["to_remove"], n > 0 { out.append("\(n) files removed") }
            if let n = removedFiles?["to_put_back"], n > 0 { out.append("\(n) files restored") }
            if let n = replacedFiles?["to_put_back"], n > 0 { out.append("\(n) originals back") }
            out.append("\(musicFilesDeleted ?? 0) music files deleted")
            return out
        }
    }

    struct TrackLyrics: Decodable, Sendable {
        var id: String
        var title: String?
        var kind: String?
        var text: String?
        var source: String?
        var instrumentalMarked: Bool?
        var instrumentalLrclib: Bool?
    }

    struct CoverCandidate: Decodable, Identifiable, Hashable, Sendable {
        var url: String
        var thumb: String?
        var source: String
        var label: String?
        var exact: Bool?
        var size: Int?
        var id: String { url }
    }

    struct CoverCandidates: Decodable, Sendable {
        var albumId: String?
        var candidates: [CoverCandidate]
    }

    struct NameCount: Decodable, Hashable, Sendable { var name: String; var tracks: Int }

    struct SpreadValue: Decodable, Hashable, Sendable { var value: Flex?; var tracks: Int }
    struct Spread: Decodable, Hashable, Sendable { var field: String; var values: [SpreadValue] }

    struct UnknownFile: Decodable, Hashable, Sendable {
        var path: String
        var title: String?
        var artist: String?
        var albumartist: String?
        var album: String?
    }

    struct HealthRow: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var album: String?
        var artist: String?
        var folder: String?
        var entries: [Entry]?
        var spread: [Spread]?
        var names: [NameCount]?
        var albums: [NameCount]?
        var files: [UnknownFile]?

        struct Entry: Decodable, Hashable, Sendable { var id: String; var tracks: Int }
    }

    struct HealthPage: Decodable, Sendable {
        var kind: String
        var total: Int
        var offset: Int
        var rows: [HealthRow]
    }

    struct Finding: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var type: String
        var title: String
        var count: Int?
        var needsYou: Bool?
        var text: String?
    }

    struct Findings: Decodable, Sendable {
        var generated: Flex?
        var findings: [Finding]
    }

    struct FixJob: Decodable, Sendable {
        var job: Int
        var run: String?
    }

    struct NewAlbums: Decodable, Sendable {
        var since: String?
        var basis: String?
        var albums: [Album]
    }

    struct Added: Decodable, Sendable { var added: [String] }

    struct Sync: Decodable, Identifiable, Hashable, Sendable {
        var ts: String?
        var mode: String?
        var result: String?
        var copied: Int?
        var removed: Int?
        var seconds: Int?
        var mac: String?
        var detail: String?
        var app: String?
        var id: String { (ts ?? "") + (mode ?? "") + (result ?? "") + String(seconds ?? 0) }
        var time: String { (ts ?? "").count >= 16 ? String((ts ?? "").dropFirst(5).prefix(11)).replacingOccurrences(of: "T", with: " ") : (ts ?? "") }
    }

    struct Syncs: Decodable, Sendable {
        var lastFinished: Sync?
        var syncs: [Sync]
    }
}

extension Panel {
    // MARK: history

    func history(q: String = "", who: String? = nil, kind: String? = nil, before: String? = nil, limit: Int = 40) async throws -> Api.History {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let who { items.append(URLQueryItem(name: "who", value: who)) }
        if let kind { items.append(URLQueryItem(name: "kind", value: kind)) }
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        return try await call("GET", "/api/history", query: items)
    }

    func run(_ run: String, offset: Int = 0, limit: Int = 100) async throws -> Api.RunDetail {
        try await call("GET", "/api/history/\(run)", query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))])
    }

    func undoPreview(_ run: String) async throws -> Api.UndoPreview { try await call("GET", "/api/history/\(run)/undo-preview") }

    func undo(_ run: String, force: Bool) async throws -> Int {
        let r: Api.JobRef = try await call("POST", "/api/history/\(run)/undo", json: force ? ["force": true] : [:])
        return r.job
    }

    // MARK: lyrics

    func lyrics(_ track: String) async throws -> Api.TrackLyrics { try await call("GET", "/api/tracks/\(track)/lyrics") }

    func pasteLyrics(_ track: String, _ text: String) async throws -> Int {
        let r: Api.JobRef = try await call("POST", "/api/tracks/\(track)/lyrics", json: ["text": text])
        return r.job
    }

    func removeLyrics(_ track: String) async throws -> Int {
        let r: Api.JobRef = try await call("DELETE", "/api/tracks/\(track)/lyrics")
        return r.job
    }

    func instrumental(track: String, _ on: Bool) async throws -> Int {
        let r: Api.JobRef = try await call("POST", "/api/tracks/\(track)/instrumental", json: ["on": on])
        return r.job
    }

    func instrumental(album: String, _ on: Bool, tracks: [String]? = nil) async throws -> Int {
        var body: [String: Any] = ["on": on]
        if let tracks { body["tracks"] = tracks }
        let r: Api.JobRef = try await call("POST", "/api/albums/\(album)/instrumental", json: body)
        return r.job
    }

    func lookupLyrics(album: String) async throws -> Int {
        let r: Api.JobRef = try await call("POST", "/api/albums/\(album)/lyrics/lookup")
        return r.job
    }

    // MARK: covers

    func covers() async throws -> [Api.Album] { try await call("GET", "/api/covers") }

    func coverCandidates(_ album: String) async throws -> Api.CoverCandidates { try await call("GET", "/api/covers/\(album)/candidates") }

    func setCover(_ album: String, url: String) async throws -> Int {
        let r: Api.JobRef = try await call("POST", "/api/covers/\(album)", json: ["url": url])
        return r.job
    }

    func setCover(_ album: String, image: Data, type: String) async throws -> Int {
        var r = try request("POST", "/api/covers/\(album)")
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        let (data, code) = try await send(r, body: image)
        guard (200..<300).contains(code), let job = Panel.object(data)["job"] as? Int else { throw Panel.failure(code, data) }
        return job
    }

    // MARK: library health

    func health(_ kind: String, limit: Int = 20, offset: Int = 0) async throws -> Api.HealthPage {
        try await call("GET", "/api/health/\(kind)", query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))])
    }

    func fixHealth(_ kind: String, _ body: [String: Any]) async throws -> Api.FixJob { try await call("POST", "/api/health/\(kind)", json: body) }

    func ignoreHealth(_ id: String) async throws {
        let _: Api.Ignored = try await call("POST", "/api/health/ignore", json: ["id": id])
    }

    func findings() async throws -> Api.Findings { try await call("GET", "/api/health/findings") }

    // MARK: the device's queue and its copy history

    func enqueue(_ device: String, _ entries: [String]) async throws {
        let _: Api.Ignored = try await call("POST", "/api/devices/\(device)/queue", json: ["entries": entries])
    }

    func queueNew(_ device: String) async throws -> Api.NewAlbums { try await call("GET", "/api/devices/\(device)/queue/new") }

    func queueAllNew(_ device: String) async throws -> [String] {
        let r: Api.Added = try await call("POST", "/api/devices/\(device)/queue/new")
        return r.added
    }

    func syncs(_ device: String, limit: Int = 30) async throws -> Api.Syncs {
        try await call("GET", "/api/devices/\(device)/syncs", query: [URLQueryItem(name: "limit", value: String(limit))])
    }
}

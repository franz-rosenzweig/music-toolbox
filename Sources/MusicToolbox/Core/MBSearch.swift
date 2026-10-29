import Foundation

/// Finding a release on MusicBrainz by whatever is known about it: artist, album, year, country, label,
/// catalog number, barcode, number of discs or tracks, or its link. Plain words find too little for an album
/// with hundreds of editions ("Revolver 2022"); a barcode or a track count finds the one.
enum MBSearch {
    struct Fields: Equatable {
        var artist = ""
        var album = ""
        var year = ""
        var country = ""
        var label = ""
        var catalog = ""
        var barcode = ""
        var discs = ""
        var tracks = ""
        var format = ""

        var isEmpty: Bool { [artist, album, year, country, label, catalog, barcode, discs, tracks, format].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    struct Found: Identifiable, Hashable, Sendable {
        var id: String
        var score: Int
        var title: String
        var artist: String
        var date: String?
        var country: String?
        var barcode: String?
        var labels: [String]
        var catalogs: [String]
        var formats: [String]
        var trackCounts: [Int]
        var disambiguation: String?

        var shape: String {
            let f = Set(formats).count == 1 ? formats[0] : (formats.isEmpty ? "" : "mixed")
            return "\(formats.count) × \(f.isEmpty ? "disc" : f)" + (trackCounts.isEmpty ? "" : " (" + trackCounts.map(String.init).joined(separator: "+") + ")")
        }
        var link: String { "https://musicbrainz.org/release/\(id)" }
    }

    /// The release ID in a musicbrainz.org/release/… link, or a bare ID.
    static func releaseID(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let m = t.firstMatch(of: #/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/#) else { return nil }
        if t.contains("musicbrainz.org") && !t.contains("/release/") { return nil }
        return String(m.1)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The Lucene query MusicBrainz's search takes: every field that is filled, ANDed.
    static func query(_ f: Fields) -> String {
        var parts: [String] = []
        func add(_ field: String, _ value: String, quote: Bool = true) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            parts.append("\(field):" + (quote ? quoted(v) : v))
        }
        add("artist", f.artist)
        add("release", f.album)
        if let y = f.year.firstMatch(of: #/(\d{4})/#) { parts.append("date:\(y.1)") }
        add("country", f.country.uppercased(), quote: false)
        add("label", f.label)
        add("catno", f.catalog)
        let digits = f.barcode.filter(\.isNumber)
        if !digits.isEmpty { parts.append("barcode:\(digits)") }
        if let n = Int(f.discs.trimmingCharacters(in: .whitespaces)) { parts.append("mediums:\(n)") }
        if let n = Int(f.tracks.trimmingCharacters(in: .whitespaces)) { parts.append("tracks:\(n)") }
        add("format", f.format)
        return parts.joined(separator: " AND ")
    }

    static func get(_ url: String) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(MusicBrainz.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        var data = Data(), status = 0
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            let (d, resp) = try await URLSession.shared.data(for: req)
            data = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 503 && status != 429 { break }
        }
        return (data, status)
    }

    static func parse(_ data: Data) -> [Found] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rs = root["releases"] as? [[String: Any]] else { return [] }
        return rs.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
            let credit = (r["artist-credit"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
            let li = r["label-info"] as? [[String: Any]] ?? []
            let media = r["media"] as? [[String: Any]] ?? []
            return Found(id: id, score: r["score"] as? Int ?? 0, title: title, artist: credit, date: r["date"] as? String, country: r["country"] as? String,
                         barcode: r["barcode"] as? String, labels: Array(Set(li.compactMap { ($0["label"] as? [String: Any])?["name"] as? String })).sorted(),
                         catalogs: Array(Set(li.compactMap { $0["catalog-number"] as? String })).sorted(),
                         formats: media.map { $0["format"] as? String ?? "" }, trackCounts: media.map { $0["track-count"] as? Int ?? 0 },
                         disambiguation: (r["disambiguation"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    static func search(_ f: Fields) async throws -> [Found] {
        let q = query(f)
        guard !q.isEmpty else { return [] }
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        comps.queryItems = [URLQueryItem(name: "query", value: q), URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "fmt", value: "json")]
        let (data, status) = try await get(comps.url!.absoluteString)
        guard status == 200 else { throw RemoteError("MusicBrainz answered \(status)") }
        return parse(data)
    }
}

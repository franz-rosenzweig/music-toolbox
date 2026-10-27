import Foundation

enum PanelError: Error, Equatable {
    case unauthorized
    case refused(String)       // the server said no, and no retry will change it
    case incomplete([String])  // finish: these files are short
    case bad([String])         // finish: these files failed their checksum and were dropped
    case server(Int)           // a gateway or server hiccup: worth retrying
    case network(String)

    var fatal: Bool {
        switch self {
        case .unauthorized, .refused: true
        case .incomplete, .bad, .server, .network: false
        }
    }

    var label: String {
        switch self {
        case .unauthorized: "Wrong password"
        case .refused(let m): m
        case .incomplete: "Files incomplete"
        case .bad: "Checksum mismatch"
        case .server(let c): "Server \(c)"
        case .network: "Can’t reach the server"
        }
    }
}

/// The panel's JSON API (docs/api.md in its repository) and upload protocol, signed in with the
/// panel's own password (HTTP Basic, sent up front).
final class Panel: @unchecked Sendable {
    let base: URL
    private let authorization: String
    private let session: URLSession
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(base: URL, user: String, password: String) {
        self.base = base
        authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpCookieStorage = nil
        session = URLSession(configuration: c)
    }

    /// For a player that needs the login on its own requests.
    var headers: [String: String] { ["Authorization": authorization] }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) throws -> URLRequest {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        r.setValue(authorization, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func send(_ r: URLRequest, body: Data? = nil, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, Int) {
        do {
            let (data, resp) = body == nil ? try await session.data(for: r, delegate: delegate) : try await session.upload(for: r, from: body!, delegate: delegate)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PanelError.network(error.localizedDescription)
        }
    }

    static func object(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

    static func failure(_ code: Int, _ data: Data) -> PanelError {
        switch code {
        case 401: .unauthorized
        case 400, 404, 409: .refused(Panel.object(data)["error"] as? String ?? "Refused")
        default: .server(code)
        }
    }

    /// One call, answered with JSON of type T.
    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil, as: T.Type = T.self) async throws -> T {
        let (data, code) = try await send(request(method, path, query: query, json: json))
        guard (200..<300).contains(code) else { throw Panel.failure(code, data) }
        do { return try Panel.decoder.decode(T.self, from: data) } catch { throw PanelError.refused("Unexpected answer") }
    }

    func health() async throws {
        let (_, code) = try await send(request("GET", "/healthz"))
        if code == 401 { throw PanelError.unauthorized }
        if code != 200 { throw PanelError.server(code) }
    }

    // MARK: devices

    func devices() async throws -> [DeviceProfile] { try await call("GET", "/api/devices") }

    func queue(_ device: String) async throws -> [Api.QueueEntry] { try await call("GET", "/api/devices/\(device)/queue") }

    func complete(_ device: String, _ entries: [String]) async throws {
        guard !entries.isEmpty else { return }
        let _: Api.Ignored = try await call("POST", "/api/devices/\(device)/queue/complete", json: ["entries": entries])
    }

    func unqueue(_ device: String, _ entries: [String]) async throws {
        let _: Api.Ignored = try await call("DELETE", "/api/devices/\(device)/queue", json: ["entries": entries])
    }

    func issues(_ device: String, scope: String = "library", limit: Int = 30) async throws -> Api.Issues {
        try await call("GET", "/api/devices/\(device)/issues", query: [URLQueryItem(name: "scope", value: scope), URLQueryItem(name: "limit", value: String(limit))])
    }

    func fix(_ device: String, all: Bool = true, paths: [String] = []) async throws -> Api.Fix {
        try await call("POST", "/api/devices/\(device)/fix", json: all ? ["all": true] : ["paths": paths])
    }

    /// One line in the panel's sync history, the one dap-sync-mac.sh writes.
    func syncLog(_ row: [String: Any]) async {
        _ = try? await send(request("POST", "/api/sync-log", json: row))
    }

    // MARK: jobs

    func job(_ id: Int) async throws -> Api.Job {
        let (data, code) = try await send(request("GET", "/api/jobs/\(id)"))
        guard code == 200 else { throw Panel.failure(code, data) }
        return Api.Job(Panel.object(data))
    }

    // MARK: library

    func search(_ q: String, limit: Int = 60, offset: Int = 0) async throws -> Api.Search {
        try await call("GET", "/api/search", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))])
    }

    func album(_ id: String) async throws -> Api.AlbumDetail { try await call("GET", "/api/albums/\(id)") }

    func track(path: String) async throws -> Api.Track { try await call("GET", "/api/tracks", query: [URLQueryItem(name: "path", value: path)]) }

    func streamURL(_ trackID: String) -> URL { url("/api/tracks/\(trackID)/stream") }

    func cover(_ albumID: String, size: Int = 128) async -> Data? {
        guard let (data, code) = try? await send({ var r = try request("GET", "/cover/\(albumID)", query: [URLQueryItem(name: "size", value: String(size))]); r.setValue("image/*", forHTTPHeaderField: "Accept"); return r }()),
              code == 200 else { return nil }
        return data
    }

    // MARK: upload

    struct Plan: Decodable, Sendable {
        var batch: String
        var files: [PlanFile]
        var have: [Int64]
        var resumed: Bool
    }
    struct PlanFile: Decodable, Sendable { var path: String; var size: Int64 }

    func start(name: String, files: [(path: String, size: Int64, sha256: String?)]) async throws -> Plan {
        let list: [[String: Any]] = files.map { f in
            var d: [String: Any] = ["path": f.path, "size": f.size]
            if let s = f.sha256 { d["sha256"] = s }
            return d
        }
        return try await call("POST", "/upload/start", json: ["name": name, "files": list])
    }

    /// Writes one chunk at `offset`. Returns the size the server now has, which is also what a 409
    /// (the offset is past the end) answers, so the caller carries on from there either way.
    func chunk(batch: String, index: Int, offset: Int64, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        var r = try request("PUT", "/upload/\(batch)/\(index)", query: [URLQueryItem(name: "offset", value: String(offset))])
        r.setValue(nil, forHTTPHeaderField: "Content-Type")
        let (body, code) = try await send(r, body: data, delegate: SendProgress(progress))
        return try Panel.chunkResult(code, body)
    }

    /// 200 and 409 both say the size the panel now has (a 409 means the offset was past the end).
    static func chunkResult(_ code: Int, _ body: Data) throws -> Int64 {
        let size = (object(body)["size"] as? NSNumber)?.int64Value
        switch code {
        case 200, 409: if let size { return size }; throw PanelError.server(code)
        default: throw failure(code, body)
        }
    }

    func have(batch: String) async throws -> [Int64] {
        let (data, code) = try await send(request("GET", "/upload/\(batch)"))
        guard code == 200, let have = Panel.object(data)["have"] as? [Any] else { throw code == 404 ? PanelError.refused("Gone") : PanelError.server(code) }
        return have.map { ($0 as? NSNumber)?.int64Value ?? 0 }
    }

    /// Hands the finished batch to the importer; the answer is its job.
    func finish(batch: String) async throws -> Int {
        let (data, code) = try await send(request("POST", "/upload/\(batch)/finish"))
        return try Panel.finishResult(code, data)
    }

    static func finishResult(_ code: Int, _ data: Data) throws -> Int {
        let o = object(data)
        switch code {
        case 200: if let j = o["job"] as? Int { return j }; throw PanelError.refused("Unexpected answer")
        case 409:
            if let bad = o["bad"] as? [String] { throw PanelError.bad(bad) }
            if let short = o["incomplete"] as? [String] { throw PanelError.incomplete(short) }
            throw PanelError.refused(o["error"] as? String ?? "Refused")
        default: throw failure(code, data)
        }
    }

    func discard(batch: String) async {
        _ = try? await send(try! request("DELETE", "/upload/\(batch)"))
    }
}

private final class SendProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}

/// The shapes the API answers with.
enum Api {
    struct Ignored: Decodable {}

    struct QueueEntry: Decodable, Sendable {
        var entry: String
        var kind: String
        var albumId: String?
        var artist: String?
        var album: String?
        var bytes: Int64
        var tracks: Int?
        var gone: Bool?
    }

    struct Album: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var artist: String
        var album: String
        var year: Int?
        var tracks: Int
        var bytes: Int64
        var hasCover: Bool
        var folder: String?
    }

    struct Track: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var path: String
        var albumId: String?
        var album: String?
        var artist: String?
        var title: String
        var disc: Int?
        var track: Int?
        var duration: Double?
        var format: String?
        var sampleRate: Int?
        var bitDepth: Int?
        var bytes: Int64?

        /// "FLAC · 44.1 kHz · 16-bit": what a file is, to tell it apart.
        var kind: String {
            var parts: [String] = []
            if let f = format { parts.append(f.uppercased()) }
            if let r = sampleRate { parts.append(String(format: "%g kHz", Double(r) / 1000)) }
            if let b = bitDepth { parts.append("\(b)-bit") }
            return parts.joined(separator: " · ")
        }
    }

    struct Search: Decodable, Sendable {
        var albums: [Album]
        var total: Int
        var tracks: [Track]?
    }

    struct AlbumDetail: Decodable, Sendable {
        var id: String
        var artist: String
        var album: String
        var year: Int?
        var tracks: [Track]
    }

    /// A value the panel may send as a number, a word or a list.
    struct Flex: Decodable, Hashable, Sendable {
        var text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(format: "%g", d) }
            else if let s = try? c.decode(String.self) { text = s }
            else if let l = try? c.decode([String].self) { text = l.joined(separator: ", ") }
            else { text = "" }
        }
    }

    struct Issue: Decodable, Identifiable, Hashable, Sendable {
        var path: String
        var albumId: String?
        var bytes: Int64?
        var check: String
        var value: Flex?
        var limit: Flex?
        var fixable: Bool
        var id: String { path + check }

        var checkLabel: String { Issues.label(check) }
    }

    struct Issues: Decodable, Sendable {
        var checked: Int
        var total: Int
        var counts: [String: Int]
        var fixable: Int
        var issues: [Issue]

        static func label(_ check: String) -> String {
            switch check {
            case "flac_blocksize": "FLAC block size"
            case "sample_rate": "Sample rate"
            case "bit_depth": "Bit depth"
            case "format": "Format"
            default: check
            }
        }
    }

    struct Fix: Decodable, Sendable {
        var job: Int
        var run: String?
    }

    struct Job: @unchecked Sendable {
        var id: Int
        var status: String
        var error: String?
        var progress: Double?
        var run: String?
        var result: [String: Any]

        var running: Bool { status == "queued" || status == "running" }
        var done: Bool { status == "done" }

        init(_ o: [String: Any]) {
            id = o["id"] as? Int ?? 0
            status = o["status"] as? String ?? "failed"
            error = o["error"] as? String
            progress = (o["progress"] as? NSNumber)?.doubleValue
            run = o["run"] as? String
            result = o["result"] as? [String: Any] ?? [:]
        }

        func int(_ key: String) -> Int? { (result[key] as? NSNumber)?.intValue }
        func count(_ key: String) -> Int? { (result[key] as? [Any])?.count }
    }
}

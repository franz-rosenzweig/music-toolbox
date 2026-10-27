import Foundation

enum PanelError: Error, Equatable {
    case unauthorized
    case refused(String)       // the server said no, and no retry will change it
    case server(Int)           // a gateway or server hiccup: worth retrying
    case network(String)

    var fatal: Bool {
        switch self {
        case .unauthorized, .refused: true
        case .server, .network: false
        }
    }

    var label: String {
        switch self {
        case .unauthorized: "Wrong password"
        case .refused(let m): m
        case .server(let c): "Server \(c)"
        case .network: "Can’t reach the server"
        }
    }
}

/// The music panel over HTTP, signed in with the panel's own password (HTTP Basic, sent up front).
final class Panel: @unchecked Sendable {
    let base: URL
    private let authorization: String
    private let session: URLSession

    struct PlanFile: Decodable, Sendable { var path: String; var size: Int64 }
    struct Plan: Decodable, Sendable {
        var batch: String
        var files: [PlanFile]
        var have: [Int64]
        var resumed: Bool
    }

    init(base: URL, user: String, password: String) {
        self.base = base
        authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpCookieStorage = nil
        session = URLSession(configuration: c)
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue(authorization, forHTTPHeaderField: "Authorization")
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

    private func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    func health() async throws {
        let (_, code) = try await send(request("GET", "/healthz"))
        if code == 401 { throw PanelError.unauthorized }
        if code != 200 { throw PanelError.server(code) }
    }

    func start(name: String, files: [(path: String, size: Int64)]) async throws -> Plan {
        var r = request("POST", "/upload/start")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "files": files.map { ["path": $0.path, "size": $0.size] }])
        let (data, code) = try await send(r, body: body)
        switch code {
        case 200: return try JSONDecoder().decode(Plan.self, from: data)
        case 401: throw PanelError.unauthorized
        case 400: throw PanelError.refused(message(data) ?? "Refused")
        default: throw PanelError.server(code)
        }
    }

    /// Appends one chunk at `offset`. Returns the size the server now has, which is also what a 409
    /// (we were out of step) answers, so the caller carries on from there either way.
    func chunk(batch: String, index: Int, offset: Int64, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let r = request("PUT", "/upload/\(batch)/\(index)", query: [URLQueryItem(name: "offset", value: String(offset))])
        let (body, code) = try await send(r, body: data, delegate: SendProgress(progress))
        let size = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["size"] as? Int64
            ?? Int64(((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["size"] as? Int ?? -1)
        switch code {
        case 200, 409: if size >= 0 { return size }; throw PanelError.server(code)
        case 401: throw PanelError.unauthorized
        case 400, 404: throw PanelError.refused(message(body) ?? "Refused")
        default: throw PanelError.server(code)
        }
    }

    func have(batch: String) async throws -> [Int64] {
        let (data, code) = try await send(request("GET", "/upload/\(batch)"))
        guard code == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let have = o["have"] as? [Any] else {
            throw code == 404 ? PanelError.refused("Gone") : PanelError.server(code)
        }
        return have.map { ($0 as? NSNumber)?.int64Value ?? 0 }
    }

    /// Hands the finished batch to the importer. The answer is the panel's job card (HTML).
    func finish(batch: String) async throws -> String {
        let (data, code) = try await send(request("POST", "/upload/\(batch)/finish"))
        if code == 401 { throw PanelError.unauthorized }
        guard code == 200 else { throw PanelError.server(code) }
        return String(decoding: data, as: UTF8.self)
    }

    func discard(batch: String) async {
        _ = try? await send(request("DELETE", "/upload/\(batch)"))
    }

    func jobCard(_ id: Int) async throws -> String {
        let (data, code) = try await send(request("GET", "/jobs/\(id)"))
        if code == 401 { throw PanelError.unauthorized }
        guard code == 200 else { throw PanelError.server(code) }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class SendProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}

/// What the panel's job card says about an import. Until the panel has a JSON answer for this,
/// the card is read for the few facts the app shows.
struct ImportCard: Equatable {
    var jobID: Int?
    var running: Bool
    var ok: Bool
    var imported: Int?
    var total: Int?
    var needLook: Int?

    init(html: String) {
        jobID = html.firstMatch(of: #/id="job-(\d+)"/#).flatMap { Int($0.1) }
        running = html.contains("hx-get=\"/jobs/")
        ok = html.contains("class=\"job ok\"")
        if let m = html.firstMatch(of: #/All (\d+) tracks matched/#) {
            total = Int(m.1); imported = total; needLook = 0
        } else if let m = html.firstMatch(of: #/(\d+) of (\d+) tracks matched/#) {
            imported = Int(m.1); total = Int(m.2)
            needLook = html.firstMatch(of: #/(\d+) tracks? need a look/#).flatMap { Int($0.1) } ?? ((total ?? 0) - (imported ?? 0))
        }
    }
}

import CryptoKit
import Foundation
import Observation

/// One file to send, as the panel's /upload sees it: a path relative to the batch.
struct StagedFile: Hashable, Codable, Sendable {
    var path: String
    var url: URL
    var size: Int64
}

/// Which files the panel takes, by the same rules as its own page: audio, lyrics and covers, nothing
/// hidden, no path deeper than six parts, nothing over 4 GB.
enum Scan {
    static let allowed: Set<String> = ["flac", "mp3", "m4a", "ogg", "opus", "wav", "aiff", "aif", "wma", "ape", "wv", "alac",
                                       "lrc", "txt", "jpg", "jpeg", "png", "webp", "cue", "log"]
    static let maxFile: Int64 = 4_000_000_000

    static func accepts(_ path: String, size: Int64) -> Bool {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, parts.count <= 6, size > 0, size <= maxFile else { return false }
        guard parts.allSatisfy({ !$0.hasPrefix(".") && $0.unicodeScalars.count <= 200 }) else { return false }
        return allowed.contains((path as NSString).pathExtension.lowercased())
    }

    /// A dropped folder keeps its own name in front of what is inside it; a dropped file is just its name.
    static func files(in urls: [URL]) -> [StagedFile] {
        var out: [StagedFile] = []
        var seen = Set<String>()
        func add(_ path: String, _ url: URL, _ size: Int64) {
            guard accepts(path, size: size), seen.insert(path).inserted else { return }
            out.append(StagedFile(path: path, url: url, size: size))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        for url in urls {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let top = url.lastPathComponent
                guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                let root = url.standardizedFileURL.path
                for case let f as URL in e {
                    let r = try? f.resourceValues(forKeys: Set(keys))
                    guard r?.isRegularFile == true else { continue }
                    let rel = String(f.standardizedFileURL.path.dropFirst(root.count + 1))
                    add(top + "/" + rel, f, Int64(r?.fileSize ?? 0))
                }
            } else if v?.isRegularFile == true {
                add(url.lastPathComponent, url, Int64(v?.fileSize ?? 0))
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

@Observable @MainActor
final class UploadJob: Identifiable {
    enum State: String, Codable { case queued, sending, paused, importing, done, failed }

    let id = UUID()
    var name: String
    var files: [StagedFile]
    var batch: String?
    var state: State = .queued
    var sent: Int64 = 0
    var rate: Double = 0
    var note = ""
    var imported: Int?
    var needLook: Int?
    var hashes: [String: String] = [:]

    var total: Int64 { files.reduce(0) { $0 + $1.size } }
    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
    var left: Double? { rate > 0 && state == .sending ? Double(total - sent) / rate : nil }

    init(name: String, files: [StagedFile]) {
        self.name = name
        self.files = files
    }
}

@Observable @MainActor
final class UploadStore {
    static let shared = UploadStore()

    static let chunk: Int64 = 8 * 1024 * 1024

    var staged: [StagedFile] = []
    var name = ""
    var scanning = false
    var jobs: [UploadJob] = []
    private var current: UploadJob?
    private var runner: Task<Void, Never>?

    var stagedBytes: Int64 { staged.reduce(0) { $0 + $1.size } }
    var folders: [(name: String, count: Int, size: Int64)] {
        var order: [String] = [], by: [String: (Int, Int64)] = [:]
        for f in staged {
            let top = f.path.contains("/") ? String(f.path.split(separator: "/")[0]) : ""
            if by[top] == nil { order.append(top) }
            by[top, default: (0, 0)].0 += 1
            by[top, default: (0, 0)].1 += f.size
        }
        return order.map { (name: $0, count: by[$0]!.0, size: by[$0]!.1) }
    }
    var active: Bool { jobs.contains { [.queued, .sending, .importing].contains($0.state) } }

    init() { restore() }

    // MARK: staging

    func add(_ urls: [URL]) async {
        scanning = true
        let found = await Task.detached { Scan.files(in: urls) }.value
        var have = Set(staged.map(\.path))
        for f in found where have.insert(f.path).inserted { staged.append(f) }
        scanning = false
        if name.isEmpty { name = Self.defaultName(for: staged) }
    }

    static func defaultName(for files: [StagedFile]) -> String {
        let tops = Set(files.map { $0.path.contains("/") ? String($0.path.split(separator: "/")[0]) : "" })
        if tops.count == 1, let t = tops.first, !t.isEmpty { return t }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Upload " + f.string(from: Date())
    }

    func clear() { staged = []; name = "" }

    func upload() {
        guard !staged.isEmpty else { return }
        let job = UploadJob(name: name.trimmingCharacters(in: .whitespaces), files: staged)
        jobs.insert(job, at: 0)
        clear()
        pump()
    }

    // MARK: running

    func pause(_ job: UploadJob) {
        if current === job { runner?.cancel() } else if job.state == .queued { job.state = .paused }
        save()
    }

    func resume(_ job: UploadJob) {
        guard job.state == .paused || job.state == .failed else { return }
        job.state = .queued
        job.note = ""
        pump()
    }

    func discard(_ job: UploadJob) {
        if current === job { runner?.cancel() }
        job.state = .failed
        jobs.removeAll { $0 === job }
        if let b = job.batch, let panel = Config.panel { Task { await panel.discard(batch: b) } }
        save()
    }

    func remove(_ job: UploadJob) { jobs.removeAll { $0 === job }; save() }

    private func pump() {
        guard runner == nil, let next = jobs.last(where: { $0.state == .queued }) else { save(); return }
        current = next
        Awake.shared.hold("Uploading music")
        runner = Task { [weak self] in
            await self?.run(next)
            guard let self else { return }
            Awake.shared.release()
            self.current = nil
            self.runner = nil
            self.save()
            self.pump()
        }
    }

    private func run(_ job: UploadJob) async {
        guard let panel = Config.panel else { job.state = .failed; job.note = "Not signed in"; return }
        job.state = .sending
        job.note = ""
        do {
            // a checksum per file, so the panel can tell if anything arrives damaged
            if job.hashes.count != job.files.count {
                job.note = "Checking files"
                let files = job.files
                let hashes = try await Task.detached { try Self.hashes(files) }.value
                job.hashes = hashes
                job.note = ""
            }
            var again = 0
            while true {
                try await send(job, panel)
                job.sent = job.total
                job.note = ""
                job.state = .importing
                save()
                do {
                    try await importing(job, panel)
                    return
                } catch let e as PanelError {
                    // the panel dropped files that failed their checksum, or says some are short: send them again
                    switch e {
                    case .bad, .incomplete where again < 3:
                        again += 1
                        job.state = .sending
                        job.note = "Sending again"
                    default: throw e
                    }
                }
            }
        } catch is CancellationError {
            job.state = .paused
            job.note = ""
        } catch let e as PanelError {
            job.state = .failed
            job.note = e.label
        } catch {
            job.state = .failed
            job.note = error.localizedDescription
        }
    }

    /// Every file, in chunks, each at the offset the panel already has.
    private func send(_ job: UploadJob, _ panel: Panel) async throws {
        let plan = try await panel.start(name: job.name, files: job.files.map { ($0.path, $0.size, job.hashes[$0.path]) })
        job.batch = plan.batch
        save()
        let byPath = Dictionary(job.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var have = plan.have
        var before: Int64 = 0                     // bytes of the files already complete
        let began = Date(), began0 = have.reduce(0, +)
        func show(_ sent: Int64) {
            job.sent = sent
            let t = Date().timeIntervalSince(began)
            if t > 1 { job.rate = Double(sent - began0) / t }
        }
        show(have.reduce(0, +))
        for (i, meta) in plan.files.enumerated() {
            guard let local = byPath[meta.path] else { throw PanelError.refused("Changed") }
            var offset = have[i]
            var wait = 1.0
            while offset < meta.size {
                try Task.checkCancellation()
                let data = try Self.read(local.url, at: offset, count: min(Self.chunk, meta.size - offset))
                let start = before + offset
                do {
                    let size = try await panel.chunk(batch: plan.batch, index: i, offset: offset, data: data) { sent in
                        Task { @MainActor in if job.state == .sending { show(start + sent) } }
                    }
                    offset = size
                    wait = 1
                    job.note = ""
                    show(before + offset)
                } catch let e as PanelError where e.fatal {
                    throw e
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // the panel writes each chunk where it belongs, so a late duplicate of this one does no harm
                    job.note = "Retrying in \(Int(wait)) s"
                    try await Task.sleep(for: .seconds(wait))
                    wait = min(wait * 2, 30)
                    if let h = try? await panel.have(batch: plan.batch), i < h.count { offset = h[i]; show(before + offset) }
                }
            }
            before += meta.size
            have[i] = meta.size
        }
    }

    private func importing(_ job: UploadJob, _ panel: Panel) async throws {
        guard let batch = job.batch else { return }
        let id = try await panel.finish(batch: batch)
        var j = try await panel.job(id)
        var polls = 0
        while j.running, polls < 450 {
            try await Task.sleep(for: .seconds(2))
            j = try await panel.job(id)
            polls += 1
        }
        job.imported = j.int("tracks_imported")
        job.needLook = j.int("tracks_left")
        job.state = j.done ? .done : .failed
        if !j.done { job.note = j.error ?? "Import failed" }
    }

    nonisolated static func hashes(_ files: [StagedFile]) throws -> [String: String] {
        var out: [String: String] = [:]
        for f in files {
            let h = try FileHandle(forReadingFrom: f.url)
            defer { try? h.close() }
            var sha = SHA256()
            while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { sha.update(data: d) }
            out[f.path] = sha.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    nonisolated static func read(_ url: URL, at offset: Int64, count: Int64) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        guard let d = try h.read(upToCount: Int(count)), Int64(d.count) == count else { throw PanelError.refused("Changed") }
        return d
    }

    // MARK: unfinished uploads survive a relaunch; the panel keeps what was sent and recognises the same files

    private struct Saved: Codable { var name: String; var files: [StagedFile]; var batch: String? }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Keychain.service, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("uploads.json")
    }

    private func save() {
        let open = jobs.filter { $0.state != .done && $0.state != .importing }
        let saved = open.map { Saved(name: $0.name, files: $0.files, batch: $0.batch) }
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }

    private func restore() {
        guard let d = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Saved].self, from: d) else { return }
        for s in saved where s.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) {
            let j = UploadJob(name: s.name, files: s.files)
            j.batch = s.batch
            j.state = .paused
            jobs.append(j)
        }
    }
}

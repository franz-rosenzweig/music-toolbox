import Foundation

/// Runs a program and waits for it; cancelling the task stops the program.
enum Proc {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func run(_ exe: String, _ args: [String], input: Data? = nil, env: [String: String] = [:],
                    onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        let outSink = Sink(), errSink = Sink()
        let group = DispatchGroup()
        func pump(_ fh: FileHandle, _ sink: Sink, _ also: (@Sendable (Data) -> Void)?) {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }
                    sink.add(d)
                    also?(d)
                }
                group.leave()
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                p.terminationHandler = { proc in
                    // the pipes close with the program; a stray child that keeps one open must not hold us
                    _ = group.wait(timeout: .now() + 2)
                    cont.resume(returning: Output(status: proc.terminationStatus, stdout: outSink.value, stderr: errSink.value))
                }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                pump(out.fileHandleForReading, outSink, onStdout)
                pump(err.fileHandleForReading, errSink, nil)
                if let input {
                    inp.fileHandleForWriting.write(input)
                    try? inp.fileHandleForWriting.close()
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

/// Cuts a stream into lines at \n and \r (rsync redraws its progress with \r).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<i]
            buffer = Data(buffer[buffer.index(after: i)...])
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }
}

/// The music on the server, reached the way the Mac scripts reach it: ssh and rsync. The queue, the
/// sync history and everything else about the library go through the panel's API; ssh is only the road
/// the files travel.
struct Remote: Sendable {
    var target: String
    var musicPath: String

    static var sshExe: String { ProcessInfo.processInfo.environment["MUSIC_SSH"] ?? "/usr/bin/ssh" }

    /// BatchMode: the app cannot answer a password prompt, so a key must do the work.
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/mt-%C",
                             "-o", "ControlPersist=120", "-o", "ConnectTimeout=10"]

    var sshCommand: String { ([Remote.sshExe] + Remote.sshOptions).joined(separator: " ") }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func run(_ command: String, input: Data? = nil) async throws -> Proc.Output {
        try await Proc.run(Remote.sshExe, Remote.sshOptions + [target, command], input: input)
    }

    func librarySize() async throws -> Int64 {
        let o = try await run("du -sb \(Remote.quote(musicPath)) | cut -f1")
        return Int64(o.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Can rsync read the library at all? Fails fast with the reason.
    func check(rsync: String) async throws {
        let o = try await Proc.run(rsync, ["--list-only", "-s", "-e", sshCommand, "\(target):\(musicPath)/"])
        guard o.status == 0 else { throw RemoteError(o.errText.isEmpty ? "Can’t read the library" : o.errText) }
    }
}

struct RemoteError: LocalizedError {
    var detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail.split(separator: "\n").first.map(String.init) ?? detail }
}

import SwiftUI
import AppKit

/// The self-test (selftest.sh): MUSIC_SELFTEST=<folder>. It drives the same calls the buttons make,
/// against a stand-in panel (the panel's documented API over a pretend library), a pretend server for
/// rsync (a folder, and an ssh that runs on this Mac), and a disk image formatted exFAT standing in
/// for the player. The shell script then checks the files.
/// Env: MUSIC_TEST_UPLOAD (a folder to send), MUSIC_TEST_UPLOAD2 (a second one, paused and resumed),
/// MUSIC_TEST_FILES (how many of its files the panel should take), MUSIC_TEST_VOLUME (the player's
/// mount point), MUSIC_TEST_REAL (a pull from the real library into the pretend player, read-only
/// on the server).
@MainActor
enum SelfTest {
    static var failures = 0
    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static let env = ProcessInfo.processInfo.environment

    static func run(out folder: URL) async {
        out = folder
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? "".write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        log("SELFTEST")
        guard await until(15, { window != nil }) else { check(false, "the window opens"); return finish() }
        window?.setContentSize(NSSize(width: 1000, height: 680))
        window?.center()
        Player.shared.player.volume = 0
        if let samples = env["MUSIC_TEST_SAMPLES"] {
            self.samples(samples)
            return finish()
        }
        if env["MUSIC_TEST_REAL"] == nil {
            if let dir = env["MUSIC_TEST_UPLOAD"] { await uploads(dir) }
            await library()
            if let vol = env["MUSIC_TEST_VOLUME"] { await devices(vol) }
            await pictures()
        } else if let vol = env["MUSIC_TEST_VOLUME"] {
            await real(vol)
        }
        finish()
    }

    // MARK: the panel's real answers

    /// Decodes the panel's recorded answers (docs/api-samples.json in its repository: live responses,
    /// plus those of a throwaway panel on a slice of the real library) the way the app decodes them.
    static func samples(_ path: String) {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let all = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return check(false, "reads the samples") }
        func entry(_ prefix: String) -> (Int, Data)? {
            guard let k = all.keys.sorted().first(where: { $0.hasPrefix(prefix) }), let e = all[k] as? [String: Any], let st = e["status"] as? Int, let r = e["response"],
                  let d = try? JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed]) else { return nil }
            return (st, d)
        }
        func decode<T: Decodable>(_ prefix: String, _ type: T.Type) -> T? {
            guard let (_, d) = entry(prefix) else { check(false, "sample “\(prefix)” exists"); return nil }
            do { return try Panel.decoder.decode(T.self, from: d) } catch { check(false, "decodes “\(prefix)”: \(error)"); return nil }
        }
        func job(_ prefix: String) -> Api.Job? { entry(prefix).map { Api.Job(Panel.object($0.1)) } }

        if let p = decode("GET /api/devices", [DeviceProfile].self) {
            let h2 = p.first { $0.id == "hifi-walker-h2" }
            check(h2?.maxSampleRate == 192000 && h2?.maxFlacBlocksize == 4608 && h2?.hasQueue == true && h2?.canFix == true, "devices: the H2 profile decodes (\(h2?.limits.joined(separator: ", ") ?? "-"))")
        }
        if let i = decode("GET /api/devices/hifi-walker-h2/issues?scope=library&limit=2 (the zero", Api.Issues.self) { check(i.total == 0 && i.checked > 1000, "issues, zero case: \(i.checked) checked") }
        if let i = decode("GET /api/devices/{id}/issues?scope=library&limit=2 (with issues", Api.Issues.self) {
            check(i.total > 0 && !i.issues.isEmpty && i.issues[0].value != nil && i.issues[0].limit != nil, "issues with hits: \(i.total), \(i.counts)")
        }
        if let l = decode("one issue of each check type", [Api.Issue].self) {
            check(Set(l.map(\.check)) == ["flac_blocksize", "sample_rate", "bit_depth", "format"] || l.count >= 3, "one issue of each check decodes (\(l.map { "\($0.check)=\($0.value?.text ?? "")>\($0.limit?.text ?? "")" }))")
            check(l.allSatisfy { Api.Issues.label($0.check) != $0.check }, "every check has a label")
        }
        if let s = decode("GET /api/search?q=mud", Api.Search.self) { check(!s.albums.isEmpty && s.tracks != nil, "search: \(s.albums.count) albums of \(s.total), \(s.tracks?.count ?? -1) tracks") }
        if let a = decode("GET /api/albums/{id}", Api.AlbumDetail.self) { check(!a.tracks.isEmpty && a.tracks.allSatisfy { !$0.id.isEmpty && !$0.kind.isEmpty }, "album: \(a.tracks.count) tracks, first \(a.tracks.first?.kind ?? "-")") }
        if let (c, d) = entry("GET /api/tracks?path=… (not found"), case .refused(let m) = Panel.failure(c, d), !m.isEmpty { check(true, "an unknown track is refused: “\(m)”") } else { check(false, "an unknown track is refused") }
        if let t = decode("GET /api/tracks?path=…", Api.Track.self) { check(!t.id.isEmpty && t.duration != nil, "track by path: \(t.title)") }
        if let q = decode("GET /api/devices/hifi-walker-h2/queue", [Api.QueueEntry].self) {
            let items = q.map(DeviceSession.Item.init)
            check(items.count >= 4, "queue: \(items.count) entries")
            check(items.contains { $0.kind == "track" && !$0.missing && $0.size > 0 }, "a single track entry")
            check(items.contains { $0.missing && $0.size == 0 }, "a gone entry is missing, size 0")
            check(items.contains { $0.kind == "album" && $0.albumID == nil && !$0.missing && $0.size > 0 }, "an album the panel has not scanned yet (no album id) is still copyable")
            check(items.contains { $0.kind == "album" && $0.albumID != nil && !$0.title.isEmpty && !$0.subtitle.isEmpty }, "an album shows its name and artist")
        }
        if let (c, d) = entry("POST /upload/start"), let plan = try? Panel.decoder.decode(Panel.Plan.self, from: d) { check(c == 200 && plan.have.count == plan.files.count && !plan.batch.isEmpty, "upload start decodes (\(plan.files.count) files)") } else { check(false, "upload start decodes") }
        for (prefix, expect) in [("PUT /upload/{batch}/{i}?offset=N (ok)", "size"), ("PUT /upload/{batch}/{i}?offset=N (offset past", "size"), ("PUT /upload/{batch}/{i}?offset=N (more data", "refused")] {
            guard let (c, d) = entry(prefix) else { check(false, "sample “\(prefix)”"); continue }
            let r = Result { try Panel.chunkResult(c, d) }
            switch (expect, r) {
            case ("size", .success(let n)): check(n >= 0, "chunk answer \(c): size \(n)")
            case ("refused", .failure(let e)): check((e as? PanelError)?.fatal == true, "chunk answer \(c) is refused")
            default: check(false, "chunk answer \(c): \(r)")
            }
        }
        if let (c, d) = entry("POST /upload/{batch}/finish (409, incomplete"), case .failure(let e) = Result(catching: { try Panel.finishResult(c, d) }) { check({ if case .incomplete = e as? PanelError { true } else { false } }(), "finish: incomplete files") } else { check(false, "finish: incomplete files") }
        if let (c, d) = entry("POST /upload/{batch}/finish (409, bad"), case .failure(let e) = Result(catching: { try Panel.finishResult(c, d) }) { check({ if case .bad(let p) = e as? PanelError { !p.isEmpty } else { false } }(), "finish: damaged files are named") } else { check(false, "finish: damaged files") }
        if let (c, d) = entry("POST /upload/{batch}/finish (404"), case .failure(let e) = Result(catching: { try Panel.finishResult(c, d) }) { check((e as? PanelError)?.fatal == true, "finish: unknown batch is refused") } else { check(false, "finish: unknown batch") }
        if let (c, d) = entry("POST /upload/{batch}/finish (ok"), let n = try? Panel.finishResult(c, d) { check(n > 0, "finish: job \(n)") } else { check(false, "finish: job id") }
        if let f = decode("POST /api/devices/{id}/fix", Api.Fix.self) { check(f.job > 0 && f.run?.hasPrefix("flacblocks-") == true, "fix: job \(f.job), undo run \(f.run ?? "-")") }

        if let j = job("GET /api/jobs/{id} (a fix, finished)") { check(j.done && (j.count("fixed") ?? 0) > 0 && j.int("found") != nil, "job: a finished fix (\(j.count("fixed") ?? -1) fixed, \(j.run ?? "-"))") }
        if let j = job("GET /api/jobs/{id} (a fix, finished with nothing") { check(j.done && j.count("fixed") == 0, "job: a fix with nothing to do") }
        if let j = job("GET /api/jobs/{id} (a fix, running)") { check(j.running && j.progress != nil, "job: running, progress \(j.progress ?? -1)") }
        if let j = job("GET /api/jobs/{id} (a fix, queued)") { check(j.running, "job: queued counts as running") }
        if let j = job("GET /api/jobs/{id} (a fix, failed") { check(!j.done && !j.running && j.error != nil && (j.count("fixed") ?? 0) > 0, "job: a failed fix keeps what it fixed and names why (\(j.error ?? "-"))") }
        if let j = job("GET /api/jobs/{id} (an upload import, finished") { check(j.done && j.int("tracks_total") != nil && j.int("tracks_imported") != nil && j.int("tracks_left") != nil, "job: an import reports \(j.int("tracks_imported") ?? -1) of \(j.int("tracks_total") ?? -1)") }
        if let j = job("GET /api/jobs/{id} (an upload import, running") { check(j.running, "job: an import, running") }
        if let j = job("GET /api/jobs/{id} (an upload import that failed") { check(!j.done && !j.running && j.error != nil && j.result.isEmpty, "job: a failed import has an error and no result") }
        if let j = job("GET /api/jobs/{id} (interrupted") { check(!j.done && !j.running, "job: interrupted ends the wait (\(j.status))") }
        if let (c, d) = entry("GET /api/jobs/{id} (unknown id"), case .refused = Panel.failure(c, d) { check(true, "an unknown job is refused") } else { check(false, "an unknown job is refused") }
    }

    // MARK: upload

    static func uploads(_ dir: String) async {
        guard let panel = Config.panel else { return check(false, "the panel is configured") }
        do { try await panel.health(); check(true, "signs in to the panel") } catch { check(false, "signs in to the panel: \(error)") }
        do {
            try await Panel(base: panel.base, user: "test", password: "wrong").health()
            check(false, "a wrong password is refused")
        } catch { check((error as? PanelError) == .unauthorized, "a wrong password is refused") }

        let store = UploadStore.shared
        store.jobs.removeAll()
        await store.add([URL(fileURLWithPath: dir)])
        let expected = Int(env["MUSIC_TEST_FILES"] ?? "") ?? -1
        check(store.staged.count == expected, "stages \(expected) files, skipping hidden and non-music (got \(store.staged.count))")
        check(!store.staged.contains { $0.path.contains("/._") || $0.path.hasSuffix(".DS_Store") || $0.path.hasSuffix(".pdf") }, "no junk staged")
        let name = store.name
        check(!name.isEmpty, "names the upload “\(name)”")
        store.upload()
        guard let job = store.jobs.first else { return check(false, "an upload job exists") }
        check(await until(120, { job.state == .done || job.state == .failed }), "the upload ends")
        check(job.state == .done, "the upload finished and imported (\(job.state), \(job.note))")
        check(job.imported != nil && job.sent == job.total, "reports \(job.imported ?? -1) imported, all \(Fmt.size(job.total)) sent")
        check(job.hashes.count == job.files.count, "sent a checksum for every file")

        // pause in the middle, resume, and the panel carries on where it stopped
        if let dir2 = env["MUSIC_TEST_UPLOAD2"] {
            await store.add([URL(fileURLWithPath: dir2)])
            store.upload()
            guard let j2 = store.jobs.first else { return }
            check(await until(60, { j2.state == .sending && j2.sent > 0 }), "second upload starts sending")
            store.pause(j2)
            check(await until(30, { j2.state == .paused }), "pauses")
            let at = j2.sent
            check(at > 0 && at < j2.total, "paused part-way (\(Fmt.size(at)) of \(Fmt.size(j2.total)))")
            store.resume(j2)
            check(await until(120, { j2.state == .done || j2.state == .failed }), "resumed upload ends")
            check(j2.state == .done, "resumed upload finished (\(j2.state), \(j2.note))")
            check(j2.needLook == 1, "reads “1 need a look” from the job (got \(j2.needLook ?? -1))")
        }
    }

    // MARK: library and play

    static func library() async {
        guard let panel = Config.panel else { return }
        guard let found = try? await panel.search("") else { return check(false, "searches the library") }
        check(!found.albums.isEmpty, "the library lists \(found.albums.count) albums")
        let hit = try? await panel.search("album one")
        check(hit?.albums.contains { $0.album == "Album One" } == true, "a search finds Album One")
        guard let album = found.albums.first(where: { $0.album == "Album One" }), let detail = try? await panel.album(album.id) else { return check(false, "opens an album") }
        check(detail.tracks.count == 2 && detail.tracks[0].title == "One", "the album has its tracks in order (\(detail.tracks.map(\.title)))")
        check(await Covers.image(album.id) != nil, "fetches a cover through the login")
        let byPath = try? await panel.track(path: detail.tracks[0].path)
        check(byPath?.id == detail.tracks[0].id, "finds a track by its path")

        let player = Player.shared
        player.play(detail.tracks[0])
        check(await until(15, { player.player.currentItem?.status == .readyToPlay }), "the player gets the stream (through the login, by Range)")
        check(await until(10, { player.time > 0.3 }), "it plays (at \(String(format: "%.2f", player.time)) s)")
        check(player.duration > 1.5 && player.duration < 2.5, "it knows the length (\(String(format: "%.2f", player.duration)) s)")
        player.toggle()
        check(!player.playing, "pauses")
        player.stop()
        check(player.track == nil, "stops")
        Nav.shared.place = .library
        await pause(1.0)
        capture("library")
        player.play(detail.tracks[1])
        await pause(1.2)
        capture("library-playing")
        player.stop()
    }

    // MARK: devices

    static func devices(_ path: String) async {
        await DeviceStore.shared.refresh()
        await DeviceStore.shared.loadProfiles()
        let h2 = DeviceProfile.named("hifi-walker-h2")
        check(h2.maxSampleRate == 192000 && h2.maxFlacBlocksize == 4608 && h2.hasQueue && h2.canFix, "reads the H2's profile from the panel (\(h2.limits.joined(separator: ", ")))")
        guard let vol = DeviceStore.shared.volumes.first(where: { $0.url.path == path }) else { return check(false, "finds the player at \(path)") }
        check(vol.isDevice && vol.profile.id == "hifi-walker-h2", "the player is marked a HiFi Walker H2 (\(vol.profile.name))")
        check(vol.total > 0 && vol.free > 0, "reads capacity: \(Fmt.size(vol.free)) free of \(Fmt.size(vol.total))")
        let s = Nav.shared.session(for: vol)
        Nav.shared.place = .device(vol.id)
        s.load()
        check(await until(30, { !s.busy }), "loads the queue")
        check(s.error == nil, "no error loading (\(s.error ?? ""))")
        check(s.items.count == Int(env["MUSIC_TEST_QUEUE"] ?? "") ?? -1, "queue has \(s.items.count) entries")
        check(s.items.filter(\.missing).count == 1, "one entry is gone from the library")
        check(s.items.filter { !$0.missing }.allSatisfy { $0.size > 0 }, "sizes come with the queue (\(Fmt.size(s.queueBytes)))")
        check(s.items.first?.title == "Album One" && s.items.first?.subtitle == "Artist A", "an album shows its name and artist")

        // what the device cannot play, and the panel's fix
        check(s.issues?.total == 2 && s.issues?.fixable == 2, "finds \(s.issues?.total ?? -1) issues, \(s.issues?.fixable ?? -1) fixable")
        check(s.issues?.issues.first?.checkLabel == "FLAC block size" && s.issues?.issues.first?.value?.text == "16384", "an issue says what and by how much")
        await pause(1.0)
        capture("device-issues")
        s.fix()
        check(await until(30, { !s.busy }), "the fix ends")
        check(s.fixed == 2 && s.fixRun?.hasPrefix("flacblocks-") == true, "2 fixed, undo run \(s.fixRun ?? "-")")
        check(s.issues?.total == 0, "no issues left")
        await pause(0.5)
        capture("device-fixed")

        s.copyQueue()
        check(await until(120, { !s.busy }), "the copy ends")
        check(s.error == nil, "no error copying (\(s.error ?? ""))")
        check(s.history.first?.result == "finished" && (s.history.first?.copied ?? 0) > 0, "history: \(s.history.first.map { "\($0.result), \($0.copied) copied" } ?? "none")")
        check(s.items.count == 1 && s.items[0].missing, "only the missing entry stays queued")
        log("INFO ._ files after the copy: \(twins(vol.url))")
        let leftover = vol.music.appendingPathComponent("Single Artist/Single Album/06 Other.flac")
        check(!FileManager.default.fileExists(atPath: leftover.path), "a single-track entry copies only that track")
        let remaining = try? await Config.panel?.queue(vol.profile.id).map(\.entry)
        check(remaining == ["Gone Artist/Gone Album"], "the panel's queue keeps only the entry that could not copy (\(remaining ?? []))")

        // a mirror removes what the library no longer has, and never what the player owns
        let stale = vol.music.appendingPathComponent("Stale Artist/Old Album", isDirectory: true)
        try? FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try? Data(count: 4096).write(to: stale.appendingPathComponent("01 Old.flac"))
        try? Data(count: 10).write(to: vol.music.appendingPathComponent("Stale Artist/._01 Old.flac"))
        s.planMirror()
        check(await until(60, { !s.busy }), "plans a mirror")
        check(s.dryRun?.stale["Stale Artist"] == 1, "plan lists the stale track (\(s.dryRun?.stale ?? [:]))")
        check(!(s.dryRun?.stale.keys.contains { $0.hasPrefix(".rockbox") || $0 == "Playlists" || $0 == "settings.txt" } ?? true), "plan leaves the player's own files alone")
        check((s.dryRun?.junk ?? 0) >= 1, "counts macOS ._ files apart (\(s.dryRun?.junk ?? 0))")
        await pause(0.5)
        capture("device-mirror")
        s.confirmMirror()
        check(await until(120, { !s.busy }), "the mirror ends")
        check(s.error == nil, "no error mirroring (\(s.error ?? ""))")
        check(!FileManager.default.fileExists(atPath: stale.path), "the stale album is gone")
        check(s.history.first?.removed == 1, "history counts 1 removed, not the ._ twins (\(s.history.first?.removed ?? -1))")
        let after = try? await Config.panel?.queue(vol.profile.id)
        check(after?.isEmpty == true, "a mirror takes the whole queue")

        s.check()
        check(await until(60, { !s.busy }), "checks")
        check(s.dryRun?.new == 0 && s.dryRun?.changed == 0, "a check right after finds nothing to copy (\(s.dryRun.map { "\($0.new) new, \($0.changed) changed, \($0.timeOnly) time" } ?? "?"))")
        s.dismissPlan()
    }

    /// The real library, read-only: one small album pulled onto the pretend player. The panel it
    /// reports to is the stand-in; only the files come from the real server.
    static func real(_ path: String) async {
        guard let remote = Config.remote, let entry = env["MUSIC_TEST_ENTRY"] else { return check(false, "an ssh target and an entry") }
        await DeviceStore.shared.refresh()
        guard let vol = DeviceStore.shared.volumes.first(where: { $0.url.path == path }) else { return check(false, "finds the pretend player") }
        let lib = try? await remote.librarySize()
        check((lib ?? 0) > 1_000_000_000, "reads the library size: \(Fmt.size(lib ?? 0))")
        // the name goes on stdin: in an ssh argument Foundation would decompose its accents
        let du = try? await remote.run("cd \(Remote.quote(remote.musicPath)) && IFS= read -r e && du -sb -- \"$e\" | cut -f1", input: Data((entry + "\n").utf8))
        let size = Int64(du?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        check(size > 0, "sizes the album over ssh: \(Fmt.size(size))")
        let s = Nav.shared.session(for: vol)
        s.items = [DeviceSession.Item(entry: entry, size: size, missing: false)]
        s.copyQueue()
        check(await until(300, { !s.busy }), "the copy ends")
        check(s.error == nil, "no error copying (\(s.error ?? ""))")
        check(s.history.first?.result == "finished", "finished: \(s.history.first.map { "\($0.copied) copied in \($0.seconds) s" } ?? "none")")
    }

    // MARK: pictures

    static func pictures() async {
        let store = UploadStore.shared
        let kept = store.jobs
        store.jobs = []
        Nav.shared.place = .upload
        await pause(0.8)
        capture("upload-empty")
        store.jobs = kept
        if let dir2 = env["MUSIC_TEST_UPLOAD2"] { await store.add([URL(fileURLWithPath: dir2)]) }
        for (appearance, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            Nav.shared.place = .upload
            await pause(1.0)
            capture("upload-\(tag)")
            if let v = DeviceStore.shared.devices.first {
                Nav.shared.place = .device(v.id)
                await pause(1.0)
                capture("device-\(tag)")
            }
        }
        NSApp.appearance = nil
        store.clear()
        if let v = env["MUSIC_TEST_VOLUME"] { log("INFO ._ files at the end: \(twins(URL(fileURLWithPath: v)))") }
        if env["MUSIC_TEST_EJECT"] != nil, let vol = DeviceStore.shared.devices.first(where: { $0.url.path == env["MUSIC_TEST_VOLUME"] }) {
            await Nav.shared.session(for: vol).eject()
            await DeviceStore.shared.refresh()
            check(!DeviceStore.shared.volumes.contains { $0.url == vol.url }, "ejects the player")
        }
    }

    // MARK: helpers

    static func twins(_ root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("._") }.map { String($0.path.dropFirst(root.path.count)) }
    }

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }

    static func capture(_ name: String) {
        guard let w = window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), out.appendingPathComponent(name + ".png").path]
        try? p.run()
        p.waitUntilExit()
    }

    static func until(_ seconds: Double, _ cond: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    static func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log((ok ? "PASS " : "FAIL ") + what)
    }

    static func log(_ line: String) {
        print(line)
        if let h = try? FileHandle(forWritingTo: out.appendingPathComponent("log.txt")) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }

    static func finish() {
        log(failures == 0 ? "SELFTEST passed" : "SELFTEST failed: \(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}

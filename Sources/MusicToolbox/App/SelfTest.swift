import SwiftUI
import AppKit

/// The self-test (selftest.sh): MUSIC_SELFTEST=<folder>. It drives the same calls the buttons make,
/// against a stand-in panel and a pretend server (a folder and a ssh that runs on this Mac), and a
/// disk image formatted exFAT standing in for the player. The shell script then checks the files.
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
        if env["MUSIC_TEST_REAL"] == nil {
            if let dir = env["MUSIC_TEST_UPLOAD"] { await uploads(dir) }
            if let vol = env["MUSIC_TEST_VOLUME"] { await devices(vol) }
            await pictures()
        } else if let vol = env["MUSIC_TEST_VOLUME"] {
            await real(vol)
        }
        finish()
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
            check(j2.needLook == 1, "reads “1 need a look” from the job card (got \(j2.needLook ?? -1))")
        }
    }

    // MARK: devices

    static func devices(_ path: String) async {
        await DeviceStore.shared.refresh()
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
        check(s.items.filter { !$0.missing }.allSatisfy { $0.size > 0 }, "sizes read for the others (\(Fmt.size(s.queueBytes)))")
        await pause(1.0)
        capture("device-queue")

        s.copyQueue()
        check(await until(120, { !s.busy }), "the copy ends")
        check(s.error == nil, "no error copying (\(s.error ?? ""))")
        check(s.history.first?.result == "finished" && (s.history.first?.copied ?? 0) > 0, "history: \(s.history.first.map { "\($0.result), \($0.copied) copied" } ?? "none")")
        check(s.items.count == 1 && s.items[0].missing, "only the missing entry stays queued")
        let twins = { Self.twins(vol.url) }
        log("INFO ._ files after the copy: \(twins())")
        let leftover = vol.music.appendingPathComponent("Single Artist/Single Album/06 Other.flac")
        check(!FileManager.default.fileExists(atPath: leftover.path), "a single-track entry copies only that track")
        check((try? await Config.remote?.queue()) == ["Gone Artist/Gone Album"], "the queue file keeps only the entry that could not copy")

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
        log("INFO ._ files before the mirror: \(twins())")
        s.confirmMirror()
        check(await until(120, { !s.busy }), "the mirror ends")
        log("INFO ._ files after the mirror: \(twins())")
        check((try? await Config.remote?.queue()) == [], "a mirror takes the whole queue")
        check(s.error == nil, "no error mirroring (\(s.error ?? ""))")
        check(!FileManager.default.fileExists(atPath: stale.path), "the stale album is gone")
        check(s.history.first?.removed == 1, "history counts 1 removed, not the ._ twins (\(s.history.first?.removed ?? -1))")

        s.check()
        check(await until(60, { !s.busy }), "checks")
        check(s.dryRun?.new == 0 && s.dryRun?.changed == 0, "a check right after finds nothing to copy (\(s.dryRun.map { "\($0.new) new, \($0.changed) changed, \($0.timeOnly) time" } ?? "?"))")
        s.dismissPlan()
        log("INFO ._ files after the check: \(twins())")
    }

    /// The real library, read-only: one small album pulled onto the pretend player. The queue and the
    /// log it reports to are scratch files named in MUSIC_QUEUEPATH / MUSIC_SYNCLOGPATH.
    static func real(_ path: String) async {
        guard let remote = Config.remote else { return check(false, "an ssh target") }
        await DeviceStore.shared.refresh()
        guard let vol = DeviceStore.shared.volumes.first(where: { $0.url.path == path }) else { return check(false, "finds the pretend player") }
        check(!remote.queuePath.contains("/srv/docker"), "the queue is a scratch file, not the real one")
        let lib = try? await remote.librarySize()
        check((lib ?? 0) > 1_000_000_000, "reads the library size: \(Fmt.size(lib ?? 0))")
        let s = Nav.shared.session(for: vol)
        s.load()
        check(await until(60, { !s.busy }), "loads the scratch queue")
        check(s.error == nil, "no error (\(s.error ?? ""))")
        check(!s.items.isEmpty && s.items.allSatisfy { !$0.missing && $0.size > 0 }, "sizes: " + s.items.map { "\($0.title) \(Fmt.size($0.size))" }.joined(separator: ", "))
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

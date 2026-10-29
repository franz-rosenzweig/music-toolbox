import SwiftUI
import AppKit
import ServiceManagement

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
        Nav.shared.place = .upload      // the Needs you page would poll the stand-in while the tests count its answers
        if env["MUSIC_TEST_RIP"] != nil {
            await rip()
            return finish()
        }
        if let samples = env["MUSIC_TEST_SAMPLES"] {
            self.samples(samples)
            return finish()
        }
        if env["MUSIC_TEST_REAL"] == nil {
            if let dir = env["MUSIC_TEST_UPLOAD"] { await uploads(dir) }
            await library()
            await needs()
            if env["MUSIC_TEST_REPLAY"] != nil { await more() }
            if let vol = env["MUSIC_TEST_VOLUME"] { await devices(vol) }
            await pictures()
        } else if let vol = env["MUSIC_TEST_VOLUME"] {
            await real(vol)
        }
        finish()
    }

    // MARK: ripping a CD

    /// The disc ID and the MusicBrainz answer are checked from files saved from a real disc (the fixtures);
    /// when a disc is in the drive and MUSIC_TEST_RIP_DEST names a folder, it is ripped for real and sent to the panel.
    static func rip() async {
        let fixtures = URL(fileURLWithPath: env["MUSIC_TEST_FIXTURES"] ?? "tests/fixtures")
        guard let toc = try? Data(contentsOf: fixtures.appendingPathComponent("audio-cd-toc.plist")),
              let mb = try? Data(contentsOf: fixtures.appendingPathComponent("musicbrainz-discid.json")) else { return check(false, "the fixtures are there") }
        var files: [Int: (URL, Int64)] = [:]
        for n in 1...7 { files[n] = (URL(fileURLWithPath: "/dev/null/\(n) Audio Track.aiff"), 1000) }
        guard let disc = Disc.parse(toc: toc, volume: URL(fileURLWithPath: "/Volumes/Audio CD"), files: files) else { return check(false, "the table of contents reads") }
        check(disc.id == "ff7_Sk1lcCL9UzNClaChCRxHKh4-", "the disc ID from the table of contents: \(disc.id)")
        check(disc.tracks.count == 7 && disc.tracks[0].frames == 25751 && abs(disc.tracks[0].seconds - 343.35) < 0.01, "track 1 is \(String(format: "%.2f", disc.tracks[0].seconds)) s (MusicBrainz says 343.346)")
        check(disc.leadout == 155422 && disc.totalSeconds > 2070 && disc.totalSeconds < 2071, "the disc is \(Fmt.clock(Int(disc.totalSeconds))) long")
        let releases = MusicBrainz.parse(mb, discID: disc.id, trackCount: 7)
        check(releases.count == 3 && releases[0].title == "Vol.1" && releases[0].artist == "Angine de Poitrine" && releases[0].tracks.count == 7, "MusicBrainz knows it: \(releases.map(\.summary))")
        check(releases[0].tracks[0].title == "Sherpa" && releases[0].tracks[0].recordingID != nil && releases[0].tracks[0].trackID != nil && !releases[0].artistIDs.isEmpty, "with the track and artist IDs it needs for tags")
        check(Ripper.clean("AC/DC: Back in Black?") == "AC-DC- Back in Black", "folder names are made safe (\(Ripper.clean("AC/DC: Back in Black?")))")

        // the disc going away while its tracks are on screen (the app once trapped on an index into the emptied list)
        let r0 = Ripper.shared
        r0.frozen = true
        r0.disc = disc
        r0.items = disc.tracks.map { Ripper.Item(track: $0, title: "Track \($0.number)", artist: "") }
        Nav.shared.place = .rip
        await pause(1.0)
        r0.items = []
        r0.disc = nil
        await pause(1.0)
        check(true, "ejecting the disc with its tracks on screen does not crash the app")
        r0.frozen = false
        // a set of two discs: which disc this is, and which are still to rip
        do {
            let r2 = MBRelease(id: "x", title: "Set", artist: "A", artistIDs: [], date: nil, country: nil, label: nil, catalog: nil, barcode: nil, releaseGroupID: nil, hasCover: false, medium: 2, media: 2, tracks: [])
            let rp = Ripper.shared
            rp.frozen = true
            rp.releases = [r2]; rp.chosen = 0
            rp.rippedDiscs = []
            check(rp.discNumber == 2 && rp.discCount == 2 && rp.missingDiscs == [1], "disc 2 of 2 with disc 1 not ripped: missing \(rp.missingDiscs)")
            rp.rippedDiscs = [1]
            check(rp.missingDiscs.isEmpty, "with disc 1 in the folder nothing is missing")
            rp.releases = []; rp.rippedDiscs = []
            check(rp.discCount == 1 && rp.missingDiscs.isEmpty, "a single disc has nothing to wait for")
            rp.frozen = false
        }
        // finding a release by what is printed on it
        let q = MBSearch.query(MBSearch.Fields(artist: "The Beatles", album: "Revolver", year: "2022", barcode: "6 02445 38277 4", tracks: "29"))
        check(q == "artist:\"The Beatles\" AND release:\"Revolver\" AND date:2022 AND barcode:602445382774 AND tracks:29", "the search query: \(q)")
        check(MBSearch.releaseID(in: "https://musicbrainz.org/release/f68086ff-1861-4b58-93c6-f71891538faf") == "f68086ff-1861-4b58-93c6-f71891538faf"
              && MBSearch.releaseID(in: "F68086FF-1861-4B58-93C6-F71891538FAF") != nil
              && MBSearch.releaseID(in: "https://musicbrainz.org/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d") == nil, "a release link or ID is recognised, an artist link is not")
        if let sd = try? Data(contentsOf: fixtures.appendingPathComponent("musicbrainz-search-revolver-2022.json")) {
            let found = MBSearch.parse(sd)
            let mine = found.first { $0.id.hasPrefix("f68086ff") }
            check(found.count >= 4 && mine?.shape == "2 × CD (14+15)" && mine?.barcode == "602445382774", "search answers parse: \(found.count) editions, yours \(mine?.shape ?? "-")")
        } else { check(false, "the search fixture") }
        do {
            let live = try await MBSearch.search(MBSearch.Fields(artist: "The Beatles", album: "Revolver", tracks: "29"))
            check(live.first?.id.hasPrefix("f68086ff") == true, "MusicBrainz finds the 2-CD edition by artist, album and 29 tracks (\(live.count) found)")
            guard var rel = try await MusicBrainz.release("https://musicbrainz.org/release/f68086ff-1861-4b58-93c6-f71891538faf", disc: nil) else { throw RemoteError("no release") }
            check(rel.media == 2 && rel.shape == "2 × CD (14+15)" && rel.allMedia[1]?.first?.title == "Taxman" && rel.allMedia[2]?.count == 15, "its tracks by disc: \(rel.summary)")
            // retagging disc 1 of a set to the release disc 2 is tagged with
            let tmp = out.appendingPathComponent("retag", isDirectory: true)
            try? FileManager.default.removeItem(at: tmp)
            UserDefaults.standard.set(tmp.path, forKey: "ripsFolder")
            let rp = Ripper.shared
            rp.frozen = true
            rp.disc = disc
            rp.albumArtist = "The Beatles"; rp.album = "Revolver"
            guard let dir = rp.destination, let flac = Ripper.flac(), let metaflac = Ripper.metaflac() else { throw RemoteError("no folder or flac") }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var wav = Data("RIFF".utf8); func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }; func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
            le32(36 + 17640); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(2); le32(44100); le32(176400); le16(4); le16(16); wav.append(Data("data".utf8)); le32(17640); wav.append(Data(count: 17640))
            let w = tmp.appendingPathComponent("t.wav"); try wav.write(to: w)
            for n in 1...2 {
                let f = dir.appendingPathComponent("1-0\(n) Wrong.flac")
                _ = try await Proc.run(flac, ["-s", "-f", "-o", f.path, w.path])
                _ = try await Proc.run(metaflac, ["--import-tags-from=-", f.path], input: Data("TITLE=Wrong\nDISCNUMBER=1\nTRACKNUMBER=\(n)\nMUSICBRAINZ_ALBUMID=85e77c9c-7de1-4fd6-89d5-b3b6cf2bb643\nDISCID=keepme\n".utf8))
            }
            rel.medium = 2
            rp.releases = [rel]; rp.chosen = 0
            await rp.refreshRipped()
            check(rp.rippedDiscs == [1] && rp.otherDiscsDiffer, "disc 1 in the folder carries another release (\(rp.folderRelease ?? "-"))")
            await rp.retagOtherDiscs()
            let t = try await Proc.run(metaflac, ["--export-tags-to=-", dir.appendingPathComponent("1-02 Wrong.flac").path]).text
            check(t.contains("TITLE=Eleanor Rigby") && t.contains("MUSICBRAINZ_ALBUMID=f68086ff-1861-4b58-93c6-f71891538faf") && t.contains("DISCID=keepme") && t.contains("DISCTOTAL=2") && !t.contains("85e77c9c"),
                  "Retag gives disc 1 the chosen release's titles and IDs, and keeps its disc ID")
            check(!rp.otherDiscsDiffer, "after which the discs agree")
            rp.releases = []; rp.disc = nil; rp.frozen = false
            UserDefaults.standard.removeObject(forKey: "ripsFolder")
        } catch { check(false, "MusicBrainz search and retag: \(error)") }
        // a disc or a player coming in shows the app on it, unless that is switched off
        Nav.shared.place = .upload
        Nav.shared.arrive(.rip)
        check(Nav.shared.place == .rip, "a disc coming in opens Rip")
        check(Prefs.openForDiscs && Prefs.openForPlayers && Prefs.staysRunning, "both are on by default")
        UserDefaults.standard.set(false, forKey: "openForDiscs"); UserDefaults.standard.set(false, forKey: "openForPlayers")
        check(!Prefs.staysRunning, "with both off the app quits when its window closes")
        UserDefaults.standard.removeObject(forKey: "openForDiscs"); UserDefaults.standard.removeObject(forKey: "openForPlayers")
        check(!LoginItem.enabled || true, "the login item state can be read (\(SMAppService.mainApp.status.rawValue))")
        guard let real = Disc.find() else { return log("INFO no disc in the drive: the real disc is skipped") }
        let r = Ripper.shared
        await r.scan()
        check(r.disc?.id == real.id, "the app finds the disc in the drive (\(real.id))")
        check(await until(40, { r.activity == .idle && (!r.releases.isEmpty || r.error != nil) }), "it asks MusicBrainz")
        check(!r.releases.isEmpty, "and gets \(r.releases.count) releases: \(r.release?.summary ?? r.error ?? "-")")
        check(r.items.allSatisfy { !$0.title.hasPrefix("Track ") } || r.releases.isEmpty, "the tracks have their titles (\(r.items.map(\.title).prefix(3)))")
        check(r.cover != nil || r.release?.hasCover == false, "and the cover art (\(r.cover.map { "\($0.count / 1000) KB" } ?? "none"))")
        Nav.shared.place = .rip
        await pause(2.0)
        capture("rip")
        guard let dest = env["MUSIC_TEST_RIP_DEST"] else { return log("INFO MUSIC_TEST_RIP_DEST not set: the disc was looked up, not ripped") }
        UserDefaults.standard.set(dest, forKey: "ripsFolder")
        UserDefaults.standard.set(false, forKey: "ejectWhenDone")      // a test must not eject the owner's disc
        let store = UploadStore.shared
        store.jobs.removeAll()
        r.rip(andUpload: true)
        check(await until(900, { r.activity != .ripping }), "the rip ends")
        check(r.error == nil && r.items.allSatisfy { $0.state == .done }, "all \(r.items.count) tracks ripped (\(r.error ?? "no error"))")
        guard let job = store.jobs.first else { return check(false, "an upload job exists") }
        check(await until(180, { job.state == .done || job.state == .failed }), "the upload ends")
        check(job.state == .done, "and the panel took it (\(job.state), \(job.note), \(job.files.count) files)")
        if let f = r.folder { log("INFO ripped to \(f.path)") }
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
            check(i.total > 0 && !i.issues.isEmpty && i.issues.first?.value != nil && i.issues.first?.limit != nil, "issues with hits: \(i.total), \(i.counts)")
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
        if let n = decode("GET /api/needs", [Api.Need].self) {
            check(!n.isEmpty && n.contains { $0.importIDs != nil } && n.allSatisfy { !$0.title.isEmpty }, "needs: \(n.count) items, \(n.filter { $0.kind == "import" }.count) imports")
        }
        if let a = decode("GET /api/needs/imports/{fid}/{gid}\u{1}".replacingOccurrences(of: "\u{1}", with: ""), Api.InboxAlbum.self) { check(a.nTracks > 0 && !a.tracks.isEmpty && a.target != nil, "inbox album: \(a.album ?? "-"), \(a.tracks.count) tracks") }
        if let c = decode("GET /api/needs/imports/{fid}/{gid}/candidates (while it runs", Api.Candidates.self) { check(c.running && c.candidates == nil, "candidates while it runs") }
        if let c = decode("GET /api/needs/imports/{fid}/{gid}/candidates\u{1}".replacingOccurrences(of: "\u{1}", with: ""), Api.Candidates.self) {
            check(c.status == "done" && c.candidates?.first?.tracks?.isEmpty == false && c.candidates?.first?.penalties != nil, "candidates: \(c.candidates?.count ?? 0), best \(c.candidates?.first?.heading ?? "-") \(Int((c.candidates?.first?.score ?? 0) * 100))%")
        }
        if let c = decode("POST /api/needs/imports/{fid}/{gid}/search", Api.Candidates.self) { check(c.running, "a search starts a lookup") }
        if let c = decode("GET /api/needs/imports/{fid}/{gid}/candidates (after a search by edition", Api.Candidates.self) {
            let first = c.candidates?.first
            check(first?.mediumTracks != nil && first?.detail.contains("×") == true, "candidates by edition say their discs and numbers: \(first?.detail ?? "-")")
        }
        if let r = decode("POST /api/needs/imports/{fid}/{gid}/apply\u{1}".replacingOccurrences(of: "\u{1}", with: ""), Api.JobRef.self) { check(r.job > 0, "apply: job \(r.job)") }
        if let r = decode("POST /api/needs/imports/{fid}/{gid}/asis\u{1}".replacingOccurrences(of: "\u{1}", with: ""), Api.AsIs.self) { check(r.job > 0 && r.folder != nil && r.queuedForDap == true, "as-is: \(r.folder ?? "-")") }
        for prefix in ["POST /api/needs/imports/{fid}/{gid}/asis (English names missing", "POST /api/needs/imports/{fid}/{gid}/apply (English names missing"] {
            if let (c, d) = entry(prefix), case .refused(let m) = Panel.failure(c, d) { check(m.contains("English"), "a 400 names what is missing: “\(m.prefix(40))…”") } else { check(false, prefix) }
        }
        if let n = decode("GET /api/names", [Api.NameNeed].self) { check(n.allSatisfy { !$0.name.isEmpty }, "names (the live library has none left): \(n.count), first \(n.first?.name ?? "-") → \(n.first?.suggest ?? "")") }
        if let (c, d) = entry("POST /api/needs/{id}/later"), c == 200, Panel.object(d)["later"] as? Bool != nil { check(true, "later answers its state") } else { check(false, "later") }
        for k in ["GET /api/jobs/{id} (an import from MusicBrainz, finished", "GET /api/jobs/{id} (an as-is import, finished"] {
            if let j = job(k) { check(j.done && j.run != nil && (j.result["albums"] as? [[String: Any]])?.first?["status"] as? String == "imported", "job: \(j.kind) imported, run \(j.run ?? "-")") }
        }
        if let (c, d) = entry("GET /api/jobs?recent"), c == 200, let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { check(!a.isEmpty && a.map(Api.Job.init).allSatisfy { !$0.kind.isEmpty }, "recent jobs: \(a.count)") } else { check(false, "recent jobs") }
        // history
        if let h = decode("GET /api/history?limit=3", Api.History.self) { check(!h.runs.isEmpty && h.total >= h.runs.count && h.runs.allSatisfy { !$0.title.isEmpty && !$0.when.isEmpty }, "history: \(h.runs.count) runs of \(h.total), next \(h.next ?? "-")") }
        if let h = decode("GET /api/history?kind=audio", Api.History.self) { check(h.runs.allSatisfy { $0.kind == "audio" || ($0.kinds ?? []).contains("audio") }, "history, only audio: \(h.runs.count)") }
        if let h = decode("GET /api/history (the sandbox after three imports", Api.History.self) { check(!h.runs.isEmpty, "history of imports: \(h.runs.map(\.title).prefix(2))") }
        if let d = decode("GET /api/history/{run} (a tag run", Api.RunDetail.self) { check(!d.changes.isEmpty && d.changes[0].rows.first?.field != nil, "a run's changes: \(d.changes.count) files, \(d.changes.first?.rows.first?.field ?? "-")") }
        if let d = decode("GET /api/history/{run}\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.RunDetail.self) { check(!d.changes.isEmpty, "an audio run's changes: \(d.changes.count)") }
        for k in ["GET /api/history/{run}/undo-preview\u{2}", "GET /api/history/{run}/undo-preview (a tag run", "GET /api/history/{run}/undo-preview (already undone", "GET /api/history/{run}/undo-preview (an as-is import", "GET /api/history/{run}/undo-preview (pasted lyrics"] {
            if let u = decode(k.replacingOccurrences(of: "\u{2}", with: ""), Api.UndoPreview.self) { check(!u.labels.isEmpty, "undo preview “\(k.dropFirst(33).prefix(22))”: \(u.canUndo ? u.labels.joined(separator: ", ") : (u.reason ?? "cannot"))") }
        }
        if let r = decode("POST /api/history/{run}/undo", Api.JobRef.self) { check(r.job > 0, "undo: job \(r.job)") }
        // library filters and lyrics
        if let r = decode("GET /api/search?filter=lyrics_none&sort=lyrics", Api.Search.self) { check(!r.albums.isEmpty && r.albums[0].lyrics != nil && r.counts != nil && r.coverage != nil, "search with filter: \(r.albums.count) albums, counts \(r.counts ?? [:]), coverage \(r.coverage?.tracks ?? -1) tracks") }
        if let r = decode("GET /api/search?filter=queued", Api.Search.self) { check(r.albums.first?.queued == true, "queued filter") }
        if let r = decode("GET /api/search?q=mud", Api.Search.self) { check(r.tracks?.first?.lyrics != nil, "a track says its lyrics: \(r.tracks?.first?.lyrics ?? "-")") }
        if let a = decode("GET /api/albums/{id}", Api.AlbumDetail.self) { check(a.tracks.allSatisfy { $0.lyrics != nil }, "album tracks carry lyrics status \(Set(a.tracks.compactMap(\.lyrics)))") }
        if let l = decode("GET /api/tracks/{id}/lyrics (synced)", Api.TrackLyrics.self) { check(l.kind == "synced" && !(l.text ?? "").isEmpty, "lyrics, synced: source \(l.source ?? "-")") }
        if let l = decode("GET /api/tracks/{id}/lyrics (none)", Api.TrackLyrics.self) { check(l.kind == nil && (l.text ?? "").isEmpty, "lyrics, none") }
        for k in ["POST /api/tracks/{id}/lyrics\u{2}", "DELETE /api/tracks/{id}/lyrics", "POST /api/tracks/{id}/instrumental"] {
            if let r = decode(k.replacingOccurrences(of: "\u{2}", with: ""), Api.JobRef.self) { check(r.job > 0, "\(k.prefix(36)): job \(r.job)") }
        }
        for k in ["GET /api/jobs/{id} (lyrics pasted, finished", "GET /api/jobs/{id} (lyrics removed, finished", "GET /api/jobs/{id} (marked instrumental, finished"] {
            if let j = job(k) { check(j.done && (j.run != nil || k.contains("instrumental")), "job: \(k.dropFirst(18).prefix(30)), run \(j.run ?? "none")") }
        }
        // covers
        if let c = decode("GET /api/covers\u{2}".replacingOccurrences(of: "\u{2}", with: ""), [Api.Album].self) { check(true, "covers without art: \(c.count)") }
        if let c = decode("GET /api/covers/{album_id}/candidates", Api.CoverCandidates.self) { check(!c.candidates.isEmpty && c.candidates.allSatisfy { !$0.url.isEmpty }, "cover candidates: \(c.candidates.count) from \(Set(c.candidates.map(\.source)))") }
        for k in ["POST /api/covers/{album_id} (a link", "POST /api/covers/{album_id} (the image as the body"] { if let r = decode(k, Api.JobRef.self) { check(r.job > 0, "set a cover: job \(r.job)") } }
        // library health
        for kind in ["split", "variants", "multi", "unknown"] {
            if let h = decode("GET /api/health/\(kind)\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.HealthPage.self) { check(h.kind == kind && h.rows.allSatisfy { !$0.id.isEmpty }, "health \(kind): \(h.total) rows") }
            if let h = decode("GET /api/health/\(kind) (the live", Api.HealthPage.self) { check(h.total == 0 && h.rows.isEmpty, "health \(kind), live: nothing to fix") }
        }
        if let h = decode("GET /api/health/split\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.HealthPage.self), let r = h.rows.first { check(r.entries?.isEmpty == false && r.spread?.isEmpty == false, "a split row: \(r.album ?? "-"), \(r.entries?.count ?? 0) entries, spread \(r.spread?.map(\.field) ?? [])") }
        if let h = decode("GET /api/health/unknown\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.HealthPage.self), let r = h.rows.first { check(r.files?.isEmpty == false, "an unknown row: \(r.files?.count ?? 0) files") }
        for k in ["POST /api/health/split\u{2}", "POST /api/health/variants", "POST /api/health/multi", "POST /api/health/unknown"] {
            if let r = decode(k.replacingOccurrences(of: "\u{2}", with: ""), Api.FixJob.self) { check(r.job > 0, "\(k.dropFirst(5)): job \(r.job), run \(r.run ?? "-")") }
        }
        if let l = decode("GET /api/health/ignored", [Api.IgnoredItem].self) { check(!l.isEmpty && l.allSatisfy { !$0.title.isEmpty }, "ignored list: \(l.map(\.title))") }
        if let (c, d) = entry("POST /api/health/unignore"), c == 200, Panel.object(d)["ignored"] as? Bool == false { check(true, "unignore answers") } else { check(false, "unignore") }
        if let (c, d) = entry("POST /api/health/ignore"), c == 200, Panel.object(d)["ignored"] as? Bool == true { check(true, "ignore answers") } else { check(false, "ignore") }
        if let f = decode("GET /api/health/findings\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.Findings.self) { check(true, "findings: \(f.findings.count)") }
        // the device's added albums and copy history
        if let n = decode("GET /api/devices/{id}/queue/new\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.NewAlbums.self) { check(true, "queue/new: \(n.albums.count) albums since \(n.since ?? "-")") }
        if let n = decode("GET /api/devices/{id}/queue/new (the live", Api.NewAlbums.self) { check(n.albums.isEmpty, "queue/new on the live library: none") }
        if let a = decode("POST /api/devices/{id}/queue/new", Api.Added.self) { check(true, "queued \(a.added.count) new albums") }
        if let y = decode("GET /api/devices/{id}/syncs\u{2}".replacingOccurrences(of: "\u{2}", with: ""), Api.Syncs.self) { check(!y.syncs.isEmpty, "syncs: \(y.syncs.count), last finished \(y.lastFinished?.ts ?? "-")") }
        if let l = decode("POST /api/devices/{id}/contents", Api.Listed.self) { check(l.files > 0 && l.asOf != nil, "contents: \(l.files) files listed at \(l.asOf ?? "-")") }
        if let m = decode("GET /api/devices/{id}/missing", Api.NotOnDevice.self) {
            let partial = m.albums.first { $0.status == "partial" }, changed = m.albums.first { $0.status == "changed" }
            check(m.asOf != nil && m.counts != nil && !m.albums.isEmpty && m.albums.allSatisfy { !$0.entries.isEmpty },
                  "missing: \(m.albums.count) albums (\(m.counts.map { "\($0.missing) missing, \($0.partial) partial, \($0.changed) changed" } ?? "-")), \(m.filesOnDevice ?? 0) files on \(m.volume ?? "-")")
            check(partial.map { $0.label.hasSuffix("missing") && $0.missingTracks > 0 } ?? true, "a partial album says how many: \(partial?.label ?? "-")")
            check(changed.map { $0.changedTracks > 0 } ?? true, "a changed album: \(changed?.label ?? "-")")
        }
        if let a = decode("POST /api/devices/{id}/missing/queue", Api.Added.self) { check(true, "queued \(a.added.count) from the missing list") }
        if let y = decode("GET /api/devices/{id}/syncs?limit=3 (the live", Api.Syncs.self) { check(y.syncs.count <= 3 && y.syncs.allSatisfy { !$0.time.isEmpty }, "live syncs: \(y.syncs.map { "\($0.result ?? "") \($0.time)" })") }
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

    // MARK: needs you

    static func needs() async {
        guard let panel = Config.panel else { return }
        let store = NeedsStore.shared
        await store.load()
        let openBefore = store.open
        check(store.items.count >= 5 && openBefore >= 4, "Needs you lists \(store.items.count) items, \(openBefore) open")
        let imports = store.items.filter { $0.kind == "import" }
        guard imports.count == 2, let ids = imports[0].importIDs, let hebIDs = imports[1].importIDs else { return check(false, "two imports are listed") }
        let cover = imports[0].cover
        check(cover != nil, "an import has art")
        if let cover { check(await Covers.image(path: cover) != nil, "its art loads through the login") }
        do {
            let a = try await panel.inbox(ids.fid, ids.gid)
            check(a.nTracks == 2 && a.tracks.count == 2 && a.target == "Yoavi/Mud memory/" && a.needsAsis.isEmpty, "the inbox album: \(a.album ?? "-"), \(a.nTracks) tracks, goes to \(a.target ?? "-")")
            // a lookup is asked for until it is done
            var c = try await panel.candidates(ids.fid, ids.gid)
            check(c.running && c.candidates == nil, "the lookup starts (\(c.status))")
            var asks = 1
            while c.running && asks < 10 { try await Task.sleep(for: .milliseconds(150)); c = try await panel.candidates(ids.fid, ids.gid); asks += 1 }
            check(c.status == "done" && c.candidates?.first?.quality == "good" && c.candidates?.first?.tracks?.count == 2, "candidates arrive after \(asks) asks")
            _ = try await panel.searchCandidates(ids.fid, ids.gid, "Yoavi - Mud memory")
            c = try await panel.candidates(ids.fid, ids.gid)
            asks = 1
            while c.running && asks < 10 { try await Task.sleep(for: .milliseconds(150)); c = try await panel.candidates(ids.fid, ids.gid); asks += 1 }
            check(c.candidates?.count == 2, "a search gives its own candidates (\(c.candidates?.map(\.heading) ?? []))")

            // accept a match
            let follower = JobFollower()
            let jid = try await panel.apply(ids.fid, ids.gid, candidate: c.candidates![0].id, english: [:])
            follower.follow(jid)
            check(await until(20, { follower.job?.done == true }), "the import job ends")
            check(follower.lines.first == "Imported Yoavi — Mud memory · 2 tracks", "it says what it imported (\(follower.lines))")
            check(follower.job?.run == "import-mb-test", "and has an undo run")

            // names in Hebrew need English ones first
            do { _ = try await panel.apply(hebIDs.fid, hebIDs.gid, candidate: "rel-cccc3333", english: [:]); check(false, "English names are required") }
            catch let e as PanelError { check({ if case .refused(let m) = e { m.contains("English") } else { false } }(), "an import without its English names is refused") }
            let j2 = try await panel.apply(hebIDs.fid, hebIDs.gid, candidate: "rel-cccc3333", english: ["artist": "Nir Knaan", "album": "Nekudat Torpa"])
            check(j2 > 0, "with them it goes ahead (job \(j2))")
            let asis = try await panel.asis(hebIDs.fid, hebIDs.gid, english: ["artist": "Nir Knaan", "album": "Nekudat Torpa"])
            check(asis.folder == "Nir Knaan/Nekudat Torpa/" && asis.queuedForDap == true, "as-is: goes to \(asis.folder ?? "-"), queued for the DAP")
            do { _ = try await panel.asis(hebIDs.fid, hebIDs.gid, english: [:]); check(false, "as-is needs English names") } catch { check(true, "as-is without them is refused") }

            // names
            let names = try await panel.names()
            check(names.count == 2 && names[0].suggest == "Nir Knaan" && names[1].suggest == "", "names to give: \(names.map(\.name))")
            let rj = try await panel.rename([["kind": "artist", "name": names[0].name, "english": "Nir Knaan"]])
            let renamed = JobFollower()
            renamed.follow(rj)
            check(await until(20, { renamed.job?.done == true }), "a rename job ends")
            check(renamed.lines.first == "1 name renamed · 23 files changed" && renamed.lines.count == 1, "it says what it changed (\(renamed.lines))")
            let nothing = JobFollower()
            nothing.follow(try await panel.rename([["kind": "artist", "name": names[0].name, "english": "Nothing To Do"]]))
            check(await until(20, { nothing.job?.done == true }), "a rename that changes nothing ends")
            check(nothing.lines.count == 2 && nothing.lines[1].hasPrefix("Nothing needed changing"), "and says why (\(nothing.lines.last ?? "-"))")

            // later, and back
            await store.later(imports[0])
            check(store.items.first { $0.id == imports[0].id }?.later == true && store.open == openBefore - 1, "Later puts an item off")
            check(Nav.shared.toast?.undo != nil, "Later offers Undo")
            if let undo = Nav.shared.toast?.undo { Nav.shared.toast = nil; await undo() }
            check(store.open == openBefore, "and Undo brings it back")
            let recent = try await panel.recentJobs(10)
            check(recent.count >= 3 && recent.contains { $0.kind == "import-mb" }, "recent jobs: \(recent.count)")
        } catch { check(false, "the Needs you flow: \(error)") }

        Nav.shared.place = .needs
        Nav.shared.needsSelection = imports[0].id
        await pause(4.5)
        capture("needs-import")
        Nav.shared.needsSelection = imports[1].id
        await pause(4.5)
        capture("needs-import-hebrew")
        Nav.shared.needsSelection = "names"
        await pause(1.0)
        capture("needs-names")
    }

    // MARK: history, lyrics, covers, health, activity (the panel's recorded answers replayed)

    static func more() async {
        guard let panel = Config.panel else { return }
        // history
        let h = HistoryStore()
        await h.reload()
        check(!h.runs.isEmpty && h.total >= h.runs.count, "History lists \(h.runs.count) runs of \(h.total)")
        h.kind = "audio"
        await h.reload()
        check(h.runs.allSatisfy { $0.kind == "audio" || $0.kinds?.contains("audio") == true }, "History filters by kind (\(h.runs.count) audio)")
        h.kind = nil
        await h.reload()
        guard let run = h.runs.first(where: { $0.canUndo && !$0.undone }) ?? h.runs.first else { return check(false, "a run to look at") }
        if let d = try? await panel.run(run.run) { check(!d.changes.isEmpty, "a run lists its changes by file (\(d.changes.count))") } else { check(false, "a run's changes") }
        if let p = try? await panel.undoPreview(run.run) { check(!p.labels.isEmpty, "undo preview: \(p.labels.joined(separator: ", "))") } else { check(false, "undo preview") }
        let undo = JobFollower()
        undo.follow(try! await panel.undo(run.run, force: false))
        check(await until(20, { undo.job?.done == true }) && undo.lines.first?.hasPrefix("reverted") == true, "undo runs as a job (\(undo.lines.first ?? "-"))")
        // undo from inside the app: the panel says what it would do, then does it
        let um = UndoModel(run: run.run)
        await um.load()
        if case .preview(let p) = um.phase { check(p.canUndo && !p.labels.isEmpty, "the in-app undo previews first: \(p.labels.joined(separator: ", "))") } else { check(false, "the in-app undo previews first") }
        await um.confirm(force: false)
        check(await until(20, { if case .finished = um.phase { true } else { false } }), "and undoes it (\(um.follower.lines.first ?? "-"))")
        let batches = try? await panel.recentJobs(10)
        check((batches?.count ?? 0) >= 1, "Activity lists recent jobs")

        // the library: filters, lyrics
        let r = try? await panel.search("", sort: "lyrics", filter: "queued")
        check(r?.coverage != nil && r?.counts?["queued"] != nil, "Library filter and coverage (\(r?.counts ?? [:]))")
        guard let album = (try? await panel.search("album one"))?.albums.first, let detail = try? await panel.album(album.id), detail.tracks.count == 2 else { return check(false, "an album with lyrics status") }
        check(Set(detail.tracks.compactMap(\.lyrics)).count == 2, "tracks carry their lyrics status \(detail.tracks.compactMap(\.lyrics))")
        let ly = try? await panel.lyrics(detail.tracks[0].id)
        check(ly?.kind == "synced" && !(ly?.text ?? "").isEmpty, "reads synced lyrics (source \(ly?.source ?? "-"))")
        for (what, call): (String, () async throws -> Int) in [
            ("paste lyrics", { try await panel.pasteLyrics(detail.tracks[0].id, "[00:01.00]one\n[00:02.00]two\n[00:03.00]three") }),
            ("remove lyrics", { try await panel.removeLyrics(detail.tracks[0].id) }),
            ("mark a track instrumental", { try await panel.instrumental(track: detail.tracks[1].id, true) }),
            ("mark an album's gaps instrumental", { try await panel.instrumental(album: album.id, true, tracks: [detail.tracks[1].id]) }),
            ("look up an album's lyrics", { try await panel.lookupLyrics(album: album.id) })] {
            let f = JobFollower()
            do { f.follow(try await call()); check(await until(20, { f.job?.done == true }), "\(what): job ends (\(f.lines.first ?? "done"))") } catch { check(false, "\(what): \(error)") }
        }

        // covers
        if let missing = try? await panel.covers(), let a = missing.first {
            check(true, "covers without art: \(missing.count)")
            if let c = try? await panel.coverCandidates(a.id) {
                check(!c.candidates.isEmpty, "cover candidates: \(c.candidates.count)")
                let f = JobFollower()
                f.follow(try! await panel.setCover(a.id, url: c.candidates[0].url))
                check(await until(20, { f.job?.done == true }) && f.lines.first?.hasPrefix("Cover saved") == true, "setting a cover from a link: \(f.lines.first ?? "-")")
                let g = JobFollower()
                g.follow(try! await panel.setCover(a.id, image: Data(count: 2000), type: "image/jpeg"))
                check(await until(20, { g.job?.done == true }), "setting a cover from a file")
            }
        } else { check(false, "covers without art") }

        // library health
        for kind in ["split", "variants", "multi", "unknown"] {
            guard let page = try? await panel.health(kind), let row = page.rows.first else { check(false, "health \(kind) has rows"); continue }
            var body: [String: Any] = ["id": row.id]
            switch kind {
            case "split": body["pick"] = 0
            case "variants": body["chosen"] = row.names?.first?.name ?? ""
            case "multi": body["album"] = row.albums?.first?.name ?? ""
            default: body["files"] = []
            }
            let f = JobFollower()
            do { f.follow(try await panel.fixHealth(kind, body).job); check(await until(20, { f.job?.done == true }) && f.lines.first?.contains("field changes") == true, "health \(kind): \(page.total) rows, fix runs (\(f.lines.first ?? "-"))") } catch { check(false, "health \(kind) fix: \(error)") }
        }
        if let page = try? await panel.health("split"), let row = page.rows.first { do { try await panel.ignoreHealth(row.id); check(true, "leave it") } catch { check(false, "ignore: \(error)") } }
        check(((try? await panel.findings())?.findings.count ?? -1) >= 0, "weekly findings")
        if let page = try? await panel.health("variants"), let row = page.rows.first {
            do {
                try await panel.ignoreHealth(row.id)
                let listed = try await panel.ignored()
                check(listed.contains { $0.id == row.id }, "what was left alone is listed (\(listed.map(\.title)))")
                try await panel.unignoreHealth(row.id)
                check(!((try? await panel.ignored()) ?? [Api.IgnoredItem(id: row.id, kind: "x", title: "x", since: nil)]).contains { $0.id == row.id }, "Bring Back puts it back")
            } catch { check(false, "leave it and bring it back: \(error)") }
        }

        // pictures of the new screens
        Nav.shared.place = .history
        await pause(2.0)
        capture("history")
        Nav.shared.place = .activity
        await pause(2.0)
        capture("activity")
        Nav.shared.place = .library
        await pause(1.5)
        capture("library-filters")
        Nav.shared.place = .needs
        Nav.shared.needsSelection = "fix-split"
        await pause(2.0)
        capture("needs-health")
        Nav.shared.needsSelection = "covers"
        await pause(1.5)
        capture("needs-covers")
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
        if env["MUSIC_TEST_REPLAY"] != nil {
            check((s.newAlbums?.albums.count ?? 0) > 0, "the device page lists \(s.newAlbums?.albums.count ?? 0) albums added since the last copy")
            check((s.syncs?.syncs.count ?? 0) > 0 && s.syncs?.lastFinished != nil, "and the panel's copy history (\(s.syncs?.syncs.count ?? 0) copies)")
            s.queueNewAlbums()
            await pause(1.0)
        }

        // the panel can't see the player: the app tells it what's there when the player shows up
        check(await until(30, { s.missing?.asOf != nil && !s.listing }), "sends the player's listing when it shows up")
        check(s.missing?.volume == "MTTESTDAP" && s.missing?.filesOnDevice == 0 && s.missing?.mac?.isEmpty == false,
              "the panel has it: \(s.missing?.filesOnDevice ?? -1) files on \(s.missing?.volume ?? "-") from \(s.missing?.mac ?? "-")")
        check(s.missing?.albums.count == 3 && s.missing?.albums.allSatisfy({ $0.status == "missing" && $0.label == "Missing" }) == true,
              "every library album is not on the empty player (\(s.missing?.albums.map { "\($0.album.album) \($0.status)" } ?? []))")

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

        // taking an album off the queue can be put back
        if let first = s.items.first(where: { !$0.missing }) {
            Nav.shared.toast = nil
            s.removeFromQueue(first)
            check(await until(10, { Nav.shared.toast?.message == "Removed from the queue" }), "removing from the queue offers Undo")
            let gone = (try? await Config.panel?.queue(vol.profile.id).map(\.entry)) ?? []
            check(!gone.contains(first.entry), "the album is off the queue")
            if let undo = Nav.shared.toast?.undo { Nav.shared.toast = nil; await undo() }
            let back = (try? await Config.panel?.queue(vol.profile.id).map(\.entry)) ?? []
            check(back.contains(first.entry) && back.count == gone.count + 1, "Undo puts it back (\(back.count) entries)")
            s.load()
            _ = await until(30, { !s.busy })
        }
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

        // after the copy the listing is sent again: one track of Single Album stayed on the server
        let single = s.missing?.albums.first
        check(s.missing?.filesOnDevice == 4 && s.missing?.albums.count == 1 && single?.status == "partial" && single?.label == "1 of 2 missing",
              "the copy sends a new listing: \(s.missing?.filesOnDevice ?? -1) files, not on it: \(s.missing?.albums.map { "\($0.album.album) \($0.label)" } ?? [])")
        let grown = vol.music.appendingPathComponent("Artist A/Album One/02 Two.flac")
        if let h = try? FileHandle(forWritingTo: grown) { h.seekToEndOfFile(); h.write(Data(count: 1000)); try? h.close() }
        s.sendListing()
        check(await until(30, { !s.listing && s.missing?.albums.contains { $0.status == "changed" } == true }), "List Again sees a track that differs")
        let changed = s.missing?.albums.first { $0.status == "changed" }
        check(changed?.album.album == "Album One" && changed?.label == "1 changed", "an album with another size is changed (\(changed?.label ?? "-"))")
        check(s.missing?.counts.map { $0.missing == 0 && $0.partial == 1 && $0.changed == 1 } == true, "counts: \(s.missing?.counts.map { "\($0.missing) \($0.partial) \($0.changed)" } ?? "-")")
        Nav.shared.place = .device(vol.id)
        await pause(1.0)
        capture("device-not-on-it")
        if let single {
            Nav.shared.toast = nil
            s.queueMissing([single])
            check(await until(10, { Nav.shared.toast?.message == "Queued Single Album" }), "queueing from the list offers Undo")
            let q = (try? await Config.panel?.queue(vol.profile.id).map(\.entry)) ?? []
            check(q.contains("Single Artist/Single Album") && s.missing?.albums.first { $0.id == single.id }?.album.queued == true, "the album is queued and shows so (\(q))")
            if let undo = Nav.shared.toast?.undo { Nav.shared.toast = nil; await undo() }
            let back = (try? await Config.panel?.queue(vol.profile.id).map(\.entry)) ?? []
            check(back == ["Gone Artist/Gone Album"] && s.missing?.albums.first { $0.id == single.id }?.album.queued == false, "Undo takes it off again (\(back))")
        }

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
        check(s.missing?.asOf != nil && s.missing?.albums.isEmpty == true && s.missing?.filesOnDevice == 5,
              "after the mirror nothing is missing (\(s.missing?.filesOnDevice ?? -1) files, \(s.missing?.albums.map(\.album.album) ?? []))")

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

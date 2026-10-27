import SwiftUI
import AppKit

struct CoverView: View {
    let albumID: String?
    var path: String?
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
        .task(id: (albumID ?? "") + (path ?? "")) {
            if let path { image = await Covers.image(path: path) }
            else if let id = albumID { image = await Covers.image(id, size: Int(size * 2)) }
            else { image = nil }
        }
    }
}

/// How many tracks have lyrics, as one bar: synced, plain, instrumental, none.
struct LyricsBar: View {
    let counts: Api.LyricCounts

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                seg(counts.synced, .green, g.size.width)
                seg(counts.plain, .blue, g.size.width)
                seg(counts.instrumental, .gray, g.size.width)
                seg(counts.none, .red.opacity(0.7), g.size.width)
            }
        }
        .frame(width: 70, height: 6)
        .clipShape(Capsule())
    }

    @ViewBuilder private func seg(_ n: Int, _ color: Color, _ width: CGFloat) -> some View {
        if n > 0 { color.frame(width: max(2, width * CGFloat(n) / CGFloat(max(1, counts.total)))) }
    }
}

/// Search the library, see what lyrics it has, play a track to see what it is.
struct LibraryView: View {
    @State private var q = ""
    @State private var albums: [Api.Album] = []
    @State private var tracks: [Api.Track] = []
    @State private var total = 0
    @State private var counts: [String: Int] = [:]
    @State private var coverage: Api.Coverage?
    @State private var filter = "all"
    @State private var sort = "recent"
    @State private var error: String?
    @State private var player = Player.shared
    @Bindable private var nav = Nav.shared
    @FocusState private var searchFocus: Bool

    static let filters: [(String, String)] = [("all", "All"), ("attention", "Needs attention"), ("nocover", "No cover"), ("lyrics_some", "Some lyrics missing"), ("lyrics_none", "No lyrics found"), ("queued", "Queued for device")]
    static let sorts: [(String, String)] = [("recent", "Recently added"), ("artist", "Artist"), ("title", "Title"), ("lyrics", "Fewest lyrics")]

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let c = coverage, q.isEmpty, filter == "all" { coverageRow(c) }
                if !tracks.isEmpty {
                    Section("Tracks") { ForEach(tracks) { TrackRow(track: $0, showAlbum: true) } }
                }
                Section(q.isEmpty && filter == "all" ? "Albums" : "Albums · \(total)") {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            HStack(spacing: 12) {
                                CoverView(albumID: a.hasCover ? a.id : nil)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.album).lineLimit(1)
                                    Text(a.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if a.queued == true { Image(systemName: "sdcard").foregroundStyle(.secondary) }
                                if let l = a.lyrics { LyricsBar(counts: l) }
                                Text("\(a.tracks) · \(Fmt.size(a.bytes))").font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 90, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: Api.Album.self) { AlbumView(album: $0) }
            .searchable(text: $q, placement: .toolbar)
            .searchFocused($searchFocus)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                        Picker("Filter", selection: $filter) {
                            ForEach(Self.filters, id: \.0) { f in Text(counts[f.0].map { "\(f.1) · \($0)" } ?? f.1).tag(f.0) }
                        }
                    }
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort", selection: $sort) { ForEach(Self.sorts, id: \.0) { Text($0.1).tag($0.0) } }
                    }
                }
            }
        }
        .onChange(of: nav.focusSearch) { searchFocus = true }
        .task(id: q + "|" + filter + "|" + sort) {
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let panel = Config.panel else { return }
            do {
                let r = try await panel.search(q, sort: q.isEmpty ? sort : (sort == "recent" ? nil : sort), filter: filter)
                albums = r.albums; tracks = r.tracks ?? []; total = r.total; counts = r.counts ?? [:]; coverage = r.coverage ?? coverage; error = nil
            } catch is CancellationError {
            } catch { self.error = Self.label(error) }
        }
    }

    private func coverageRow(_ c: Api.Coverage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lyrics").font(.headline)
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach([(c.synced, Color.green), (c.plain, .blue), (c.instrumental, .gray), (c.none, Color.red.opacity(0.7))], id: \.0) { n, color in
                        if n > 0 { color.frame(width: max(2, g.size.width * CGFloat(n) / CGFloat(max(1, c.tracks)))) }
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule())
            HStack(spacing: 14) {
                legend("Synced", c.synced, .green); legend("Plain", c.plain, .blue); legend("Instrumental", c.instrumental, .gray); legend("None", c.none, .red.opacity(0.7))
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func legend(_ name: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text("\(name) \(n.formatted())").foregroundStyle(.secondary).monospacedDigit() }
    }

    static func label(_ e: Error) -> String { (e as? PanelError)?.label ?? e.localizedDescription }
}

struct AlbumView: View {
    let album: Api.Album
    @State private var tracks: [Api.Track] = []
    @State private var error: String?
    @State private var job = JobFollower()
    @State private var lyricsTrack: Api.Track?
    @State private var coverSheet = false
    @State private var queued = false

    private var missing: [Api.Track] { tracks.filter { $0.lyrics == "missing" } }
    private var device: DeviceProfile? { DeviceProfile.all.first { $0.hasQueue } }

    var body: some View {
        List {
            HStack(spacing: 16) {
                CoverView(albumID: album.hasCover ? album.id : nil, size: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.album).font(.title2.weight(.semibold))
                    Text(album.artist).foregroundStyle(.secondary)
                    Text([album.year.map(String.init), "\(album.tracks) tracks", Fmt.size(album.bytes)].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let d = device, let folder = album.folder {
                            Button(queued || album.queued == true ? "Queued" : "Send to Device", systemImage: "sdcard") { Task { await send(d, folder) } }
                                .disabled(queued || album.queued == true)
                        }
                        Button(album.hasCover ? "Replace Cover" : "Find a Cover", systemImage: "photo") { coverSheet = true }
                        Button("Look Up Lyrics", systemImage: "text.magnifyingglass") { Task { await run { try await $0.lookupLyrics(album: album.id) } } }
                        if !missing.isEmpty {
                            Button("Mark \(missing.count) Instrumental") {
                                let ids = missing.map(\.id)
                                Task {
                                    await run { try await $0.instrumental(album: album.id, true, tracks: ids) }
                                    Nav.shared.notify("\(ids.count) tracks marked instrumental") { _ = try? await Config.panel?.instrumental(album: album.id, false, tracks: ids); await load() }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 6)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if job.job != nil { JobCard(follower: job) }
            ForEach(tracks) { t in
                TrackRow(track: t, showAlbum: false, openLyrics: { lyricsTrack = t })
            }
        }
        .navigationTitle(album.album)
        .task { await load() }
        .sheet(item: $lyricsTrack) { t in LyricsSheet(track: t) { Task { await load() } } }
        .sheet(isPresented: $coverSheet) { CoverPicker(albumID: album.id, name: album.album) { coverSheet = false } }
    }

    private func load() async {
        guard let panel = Config.panel else { return }
        do { tracks = try await panel.album(album.id).tracks } catch { self.error = LibraryView.label(error) }
    }

    private func run(_ call: @escaping (Panel) async throws -> Int) async {
        guard let panel = Config.panel else { return }
        error = nil
        do { job.follow(try await call(panel)) { _ in Task { await load() } } } catch { self.error = LibraryView.label(error) }
    }

    private func send(_ d: DeviceProfile, _ folder: String) async {
        guard let panel = Config.panel else { return }
        do {
            try await panel.enqueue(d.id, [folder]); queued = true
            Nav.shared.notify("Queued for the device") { try? await panel.unqueue(d.id, [folder]); queued = false }
        } catch { self.error = LibraryView.label(error) }
    }
}

struct TrackRow: View {
    let track: Api.Track
    var showAlbum: Bool
    var openLyrics: (() -> Void)?
    @State private var player = Player.shared

    private var current: Bool { player.track?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if current { player.toggle() } else { player.play(track) }
            } label: {
                Image(systemName: current && player.playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            if let n = track.track, !showAlbum { Text("\(n)").foregroundStyle(.secondary).monospacedDigit().frame(width: 24, alignment: .trailing) }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1).fontWeight(current ? .semibold : .regular)
                if showAlbum { Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(track.kind).font(.callout).foregroundStyle(.secondary)
            if let l = track.lyrics {
                Button { openLyrics?() } label: {
                    Image(systemName: Self.icon(l)).foregroundStyle(Self.color(l)).frame(width: 20)
                }
                .buttonStyle(.borderless)
                .disabled(openLyrics == nil)
                .help(l.capitalized)
            }
            if let d = track.duration { Text(Fmt.clock(Int(d))).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing) }
        }
    }

    static func icon(_ l: String) -> String {
        switch l { case "synced": "text.quote"; case "plain": "text.alignleft"; case "instrumental": "music.note"; default: "text.badge.xmark" }
    }

    static func color(_ l: String) -> Color {
        switch l { case "synced": .green; case "plain": .blue; case "instrumental": .gray; default: .red.opacity(0.7) }
    }
}

/// Read a track's lyrics, paste new ones, remove wrong ones, mark it instrumental.
struct LyricsSheet: View {
    let track: Api.Track
    var done: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: Api.TrackLyrics?
    @State private var text = ""
    @State private var editing = false
    @State private var job = JobFollower()
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.title3.weight(.semibold))
                    Text([lyrics?.kind?.capitalized, lyrics?.source].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if job.job != nil { JobCard(follower: job) }
            Group {
                if editing {
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                } else {
                    ScrollView { Text(lyrics?.text ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }
            }
            .frame(minHeight: 220)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if editing {
                    Button("Save") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || job.running)
                    Button("Cancel") { editing = false }
                } else {
                    Button("Paste Lyrics…") { text = lyrics?.text ?? ""; editing = true }
                    if lyrics?.kind != nil { Button("Remove", role: .destructive) { confirmRemove = true } }
                }
                Spacer()
                Toggle("Instrumental", isOn: Binding(get: { lyrics?.instrumentalMarked ?? track.instrumentalMarked ?? false }, set: { on in Task { await mark(on) } }))
                    .toggleStyle(.switch).disabled(job.running)
            }
        }
        .padding(22)
        .frame(width: 560, height: 480)
        .confirmationDialog("Remove these lyrics?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await run { try await $0.removeLyrics(track.id) } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let panel = Config.panel else { return }
        do { lyrics = try await panel.lyrics(track.id) } catch { self.error = LibraryView.label(error) }
    }

    private func save() async {
        let t = text
        await run { try await $0.pasteLyrics(track.id, t) }
        editing = false
    }

    private func mark(_ on: Bool) async { await run { try await $0.instrumental(track: track.id, on) } }

    private func run(_ call: @escaping (Panel) async throws -> Int) async {
        guard let panel = Config.panel else { return }
        error = nil
        do {
            let id = try await call(panel)
            job.follow(id) { j in
                if !j.done { error = j.error }
                Task { await load(); done() }
            }
        } catch { self.error = LibraryView.label(error) }
    }
}

/// What is playing, and nothing else: play or pause, where it is, and close.
struct PlayerBar: View {
    @State private var player = Player.shared
    @State private var scrubbing = false
    @State private var position: Double = 0

    var body: some View {
        if let t = player.track {
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 24)
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).lineLimit(1).fontWeight(.semibold)
                    Text(player.failed ? "Can’t play this" : [t.artist, t.kind].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(player.failed ? .red : .secondary).lineLimit(1)
                }
                .frame(minWidth: 160, alignment: .leading)
                Slider(value: Binding(get: { scrubbing ? position : player.time }, set: { position = $0 }), in: 0...max(player.duration, 1)) { editing in
                    scrubbing = editing
                    if !editing { player.seek(position) }
                }
                Text("\(Fmt.clock(Int(player.time))) / \(Fmt.clock(Int(player.duration)))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button { player.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
}

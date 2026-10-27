import SwiftUI

struct CoverView: View {
    let albumID: String?
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
        .task(id: albumID) {
            guard let id = albumID else { image = nil; return }
            image = await Covers.image(id, size: Int(size * 2))
        }
    }
}

/// Search the library and play a track to see what it is.
struct LibraryView: View {
    @State private var q = ""
    @State private var albums: [Api.Album] = []
    @State private var tracks: [Api.Track] = []
    @State private var total = 0
    @State private var error: String?
    @State private var player = Player.shared

    var body: some View {
        NavigationStack {
            List {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if !tracks.isEmpty {
                    Section("Tracks") { ForEach(tracks) { TrackRow(track: $0, showAlbum: true) } }
                }
                Section(q.isEmpty ? "Newest" : "Albums · \(total)") {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            HStack(spacing: 12) {
                                CoverView(albumID: a.hasCover ? a.id : nil)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.album).lineLimit(1)
                                    Text(a.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(a.tracks) · \(Fmt.size(a.bytes))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: Api.Album.self) { AlbumView(album: $0) }
            .searchable(text: $q, placement: .toolbar)
            .navigationTitle("Library")
        }
        .task(id: q) {
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let panel = Config.panel else { return }
            do {
                let r = try await panel.search(q)
                albums = r.albums; tracks = r.tracks ?? []; total = r.total; error = nil
            } catch is CancellationError {
            } catch { self.error = Self.label(error) }
        }
    }

    static func label(_ e: Error) -> String { (e as? PanelError)?.label ?? e.localizedDescription }
}

struct AlbumView: View {
    let album: Api.Album
    @State private var tracks: [Api.Track] = []
    @State private var error: String?

    var body: some View {
        List {
            HStack(spacing: 16) {
                CoverView(albumID: album.hasCover ? album.id : nil, size: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.album).font(.title2.weight(.semibold))
                    Text(album.artist).foregroundStyle(.secondary)
                    Text([album.year.map(String.init), "\(album.tracks) tracks", Fmt.size(album.bytes)].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ForEach(tracks) { TrackRow(track: $0, showAlbum: false) }
        }
        .navigationTitle(album.album)
        .task {
            guard let panel = Config.panel else { return }
            do { tracks = try await panel.album(album.id).tracks } catch { self.error = LibraryView.label(error) }
        }
    }
}

struct TrackRow: View {
    let track: Api.Track
    var showAlbum: Bool
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
            if let d = track.duration { Text(Fmt.clock(Int(d))).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing) }
        }
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

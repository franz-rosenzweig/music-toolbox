import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pick a cover for an album: the services' candidates, or an image from this Mac.
struct CoverPicker: View {
    let albumID: String
    let name: String
    var done: () -> Void

    @State private var candidates: [Api.CoverCandidate]?
    @State private var chosen: String?
    @State private var job = JobFollower()
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(name).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("Close") { done() }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if job.job != nil { JobCard(follower: job) }
            if let list = candidates {
                if list.isEmpty { Text("No covers found").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120) }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(list) { c in
                            Button { chosen = c.url } label: {
                                VStack(spacing: 4) {
                                    AsyncImage(url: URL(string: c.thumb ?? c.url)) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                        .frame(width: 130, height: 130).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen == c.url ? Color.accentColor : .clear, lineWidth: 3))
                                    Text([Self.source(c.source), c.size.map { "\($0) px" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    if c.exact == true { Text("Exact").font(.caption2).foregroundStyle(.green) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Searching").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Button("Use This Cover") { Task { await use() } }.buttonStyle(.borderedProminent).disabled(chosen == nil || job.running)
                Button("Choose File…") { Task { await pick() } }.disabled(job.running)
            }
        }
        .padding(22)
        .frame(width: 620, height: 520)
        .task { await load() }
    }

    static func source(_ s: String) -> String { ["caa": "Cover Art Archive", "apple": "Apple Music", "deezer": "Deezer"][s] ?? s.capitalized }

    private func load() async {
        guard let panel = Config.panel else { return }
        do { candidates = try await panel.coverCandidates(albumID).candidates } catch { self.error = LibraryView.label(error); candidates = [] }
    }

    private func use() async {
        guard let panel = Config.panel, let url = chosen else { return }
        error = nil
        do { follow(try await panel.setCover(albumID, url: url)) } catch { self.error = LibraryView.label(error) }
    }

    private func pick() async {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url), let panel = Config.panel else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        do { follow(try await panel.setCover(albumID, image: data, type: type)) } catch { self.error = LibraryView.label(error) }
    }

    private func follow(_ id: Int) {
        job.follow(id) { j in
            if !j.done { error = j.error }
            Task { await NeedsStore.shared.load() }
        }
    }
}

/// Albums with no cover: find one for each.
struct CoversNeedView: View {
    @State private var albums: [Api.Album] = []
    @State private var sheet: Api.Album?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Albums with no cover").font(.title2.weight(.semibold))
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                VStack(spacing: 0) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider() }
                        HStack(spacing: 12) {
                            CoverView(albumID: nil, size: 40)
                            VStack(alignment: .leading, spacing: 1) { Text(a.album).lineLimit(1); Text(a.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Button("Find a Cover") { sheet = a }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .sheet(item: $sheet) { a in CoverPicker(albumID: a.id, name: a.album) { sheet = nil; Task { await load() } } }
    }

    private func load() async {
        guard let panel = Config.panel else { return }
        do { albums = try await panel.covers() } catch { self.error = LibraryView.label(error) }
    }
}

/// The weekly health report's items that have no fix screen, in its own words.
struct FindingsView: View {
    @State private var findings: [Api.Finding] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Weekly health check").font(.title2.weight(.semibold))
                ForEach(findings) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.title).font(.headline)
                        if let t = f.text { Text(t).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { findings = (try? await Config.panel?.findings().findings) ?? [] }
    }
}

// MARK: the four tag fixes

struct HealthView: View {
    let kind: String

    @State private var rows: [Api.HealthRow] = []
    @State private var total = 0
    @State private var error: String?
    @State private var loaded = false

    static func title(_ k: String) -> String {
        switch k {
        case "split": "Albums split into several entries"
        case "variants": "Artist spelled more than one way"
        case "multi": "Folders holding more than one album"
        default: "Files with no album or artist"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(Self.title(kind)) · \(total)").font(.title2.weight(.semibold))
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                ForEach(rows) { row in
                    HealthRowView(kind: kind, row: row) { Task { await load(); await NeedsStore.shared.load() } }
                }
                if rows.count < total { Button("More") { Task { await more() } }.buttonStyle(.link) }
                if loaded && rows.isEmpty { Image(systemName: "checkmark.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary).frame(maxWidth: .infinity) }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: kind) { await load() }
    }

    private func load() async {
        guard let panel = Config.panel else { return }
        do { let p = try await panel.health(kind); rows = p.rows; total = p.total; error = nil } catch { self.error = LibraryView.label(error) }
        loaded = true
    }

    private func more() async {
        guard let panel = Config.panel, let p = try? await panel.health(kind, offset: rows.count) else { return }
        rows += p.rows
    }
}

struct HealthRowView: View {
    let kind: String
    let row: Api.HealthRow
    var changed: () -> Void

    @State private var picks: [String: Int] = [:]          // split: per tag, which value
    @State private var chosen: String?                     // variants, multi
    @State private var files: [String: Api.UnknownFile] = [:]
    @State private var job = JobFollower()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.headline).lineLimit(2)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if job.job != nil { JobCard(follower: job) }
            switch kind {
            case "split": split
            case "variants": choices((row.names ?? []).map { ($0.name, $0.tracks) }, button: "Use This Spelling", key: "chosen")
            case "multi": choices((row.albums ?? []).map { ($0.name, $0.tracks) }, button: "Use This Album Name", key: "album")
            default: unknown
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var heading: String {
        switch kind {
        case "split": [row.album, row.artist].compactMap { $0 }.joined(separator: " — ")
        default: row.folder ?? row.id
        }
    }

    private var ignoreLabel: String { kind == "split" ? "They’re Different Albums" : kind == "variants" ? "They’re Different Artists" : "Leave It" }

    private var buttons: some View {
        Button(ignoreLabel) { Task { await ignore() } }.disabled(job.running)
    }

    // split: every tag that has several values, with the choices
    private var split: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(row.entries?.count ?? 0) entries").foregroundStyle(.secondary)
            ForEach(row.spread ?? [], id: \.field) { sp in
                HStack(alignment: .top) {
                    Text(sp.field).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Picker(sp.field, selection: Binding(get: { picks[sp.field] ?? 0 }, set: { picks[sp.field] = $0 })) {
                        ForEach(Array(sp.values.enumerated()), id: \.offset) { i, v in Text("\(v.value?.text ?? "") · \(v.tracks)").tag(i) }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Button("Make It One Album") { Task { await fixSplit() } }.buttonStyle(.borderedProminent).disabled(job.running)
                buttons
            }
        }
    }

    private func choices(_ list: [(String, Int)], button: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(list, id: \.0) { name, n in
                Button { chosen = name } label: {
                    HStack { Image(systemName: chosen == name ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen == name ? Color.accentColor : .secondary); Text(name); Spacer(); Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button(button) { Task { await send(["id": row.id, key: chosen ?? ""]) } }.buttonStyle(.borderedProminent).disabled(chosen == nil || job.running)
                buttons
            }
        }
    }

    private var unknown: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.files ?? [], id: \.path) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text((f.path as NSString).lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    HStack {
                        field("Title", f, \.title, "title"); field("Artist", f, \.artist, "artist"); field("Album artist", f, \.albumartist, "albumartist"); field("Album", f, \.album, "album")
                    }
                }
            }
            HStack {
                Button("Save") { Task { await saveUnknown() } }.buttonStyle(.borderedProminent).disabled(job.running || edits.isEmpty)
                buttons
            }
        }
    }

    private func field(_ label: String, _ f: Api.UnknownFile, _ kp: KeyPath<Api.UnknownFile, String?>, _ key: String) -> some View {
        TextField(label, text: Binding(
            get: { (edited[f.path]?[key]) ?? (f[keyPath: kp] ?? "") },
            set: { edited[f.path, default: [:]][key] = $0 }
        )).textFieldStyle(.roundedBorder)
    }

    @State private var edited: [String: [String: String]] = [:]

    private var edits: [[String: Any]] {
        (row.files ?? []).compactMap { f in
            guard let e = edited[f.path] else { return nil }
            let current = ["title": f.title ?? "", "artist": f.artist ?? "", "albumartist": f.albumartist ?? "", "album": f.album ?? ""]
            let diff = e.filter { current[$0.key] != $0.value }
            return diff.isEmpty ? nil : (["path": f.path].merging(diff) { a, _ in a })
        }
    }

    private func fixSplit() async {
        let spread = row.spread ?? []
        let isDefault = picks.values.allSatisfy { $0 == 0 }
        if isDefault || spread.isEmpty { await send(["id": row.id, "pick": 0]); return }
        var fields: [String: Any] = [:]
        for sp in spread { let i = picks[sp.field] ?? 0; if i < sp.values.count, let v = sp.values[i].value { fields[sp.field] = v.text } }
        await send(["id": row.id, "fields": fields])
    }

    private func saveUnknown() async { await send(["id": row.id, "files": edits]) }

    private func send(_ body: [String: Any]) async {
        guard let panel = Config.panel else { return }
        error = nil
        do {
            let r = try await panel.fixHealth(kind, body)
            job.follow(r.job) { j in
                if !j.done { error = j.error }
                changed()
            }
        } catch { self.error = LibraryView.label(error) }
    }

    private func ignore() async {
        guard let panel = Config.panel else { return }
        let id = row.id
        do {
            try await panel.ignoreHealth(id)
            changed()
            Nav.shared.notify("Left alone") { try? await panel.unignoreHealth(id); changed() }
        } catch { self.error = LibraryView.label(error) }
    }
}

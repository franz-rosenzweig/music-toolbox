import SwiftUI
import AppKit

/// Needs you: what waits on a decision, and the decision beside it.
struct NeedsView: View {
    @State private var store = NeedsStore.shared
    @Bindable private var nav = Nav.shared

    private var selected: Api.Need? { store.items.first { $0.id == nav.needsSelection } ?? store.items.first { $0.open && !$0.later } ?? store.items.first }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $nav.needsSelection) {
                ForEach(["imports", "health", "device"], id: \.self) { group in
                    let rows = store.items.filter { $0.group == group }
                    if !rows.isEmpty {
                        Section(Self.groupName(group)) {
                            ForEach(rows) { NeedRow(need: $0).tag($0.id) }
                        }
                    }
                }
            }
            .frame(width: 330)
            Divider()
            Group {
                if let n = selected {
                    switch n.kind {
                    case "import": ImportView(need: n).id(n.id)
                    case "names": NamesView().id(n.id)
                    case "covers": CoversNeedView().id(n.id)
                    case "fix": HealthView(kind: n.fix ?? "split").id(n.id)
                    case "finding": FindingsView().id(n.id)
                    default: OutsideView(need: n)
                    }
                } else if store.loaded {
                    Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Needs You")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await store.load() } }
            }
        }
        .overlay(alignment: .top) {
            if let e = store.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8) }
        }
        .task { await store.load() }
    }

    static func groupName(_ g: String) -> String {
        switch g { case "imports": "Imports"; case "health": "Library health"; default: "Device" }
    }
}

struct NeedRow: View {
    let need: Api.Need
    @State private var store = NeedsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            if need.cover != nil { CoverView(albumID: nil, path: need.cover, size: 40) }
            else {
                Image(systemName: Self.icon(need.kind)).frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(need.title).lineLimit(1)
                Text(need.sub).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .opacity(need.later ? 0.5 : 1)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(need.later ? "Bring Back" : "Later") { Task { await store.later(need) } }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "names": "textformat"
        case "covers": "photo"
        case "fix": "list.bullet"
        case "dap": "sdcard"
        default: "list.bullet"
        }
    }
}

/// What the app cannot decide yet is opened on the panel itself.
struct OutsideView: View {
    let need: Api.Need

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: NeedRow.icon(need.kind)).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(need.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Button("Open in Panel") {
                if let p = Config.panel { NSWorkspace.shared.open(p.url("/")) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

// MARK: an import

struct ImportView: View {
    let need: Api.Need

    @State private var album: Api.InboxAlbum?
    @State private var cands: Api.Candidates?
    @State private var chosen: String?
    @State private var english: [String: String] = [:]
    @State private var query = ""
    @State private var error: String?
    @State private var job = JobFollower()
    @State private var store = NeedsStore.shared

    private var busy: Bool { job.running || job.active }
    private var candidate: Api.Candidate? { cands?.candidates?.first { $0.id == chosen } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if job.job != nil { JobCard(follower: job) }
                musicBrainz
                asis
                tracks
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: need.id) { await load() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(albumID: nil, path: album?.art ?? need.cover, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(album?.album ?? need.title).font(.title2.weight(.semibold))
                Text([album?.artist, album?.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                if let a = album {
                    Text([ "\(a.nTracks) tracks", a.duration.map { Fmt.clock(Int($0)) }, a.bytes.map { Fmt.size($0) }, a.format].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(Self.state(a.state)).font(.callout).foregroundStyle(a.state == "pending" ? .orange : .secondary)
                }
            }
            Spacer()
            Button(need.later ? "Bring Back" : "Later") { Task { await store.later(need) } }
        }
    }

    static func state(_ s: String) -> String {
        switch s { case "pending": "Needs a decision"; case "arriving": "Still arriving"; default: "Waiting" }
    }

    // MARK: MusicBrainz

    private var musicBrainz: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MusicBrainz").font(.title3.weight(.semibold))
                Spacer()
                if cands?.running == true { ProgressView().controlSize(.small) }
            }
            HStack {
                TextField("Artist - Album, or a release link", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(query.isEmpty || busy)
            }
            if let e = cands?.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if let list = cands?.candidates {
                if list.isEmpty { Text("No match").foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider() }
                        CandidateRow(c: c, chosen: chosen == c.id) { chosen = c.id }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                if let c = candidate { candidateDetail(c) }
            }
        }
    }

    private func candidateDetail(_ c: Api.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("\(c.matched ?? 0) of \(c.ofFiles ?? 0) files").monospacedDigit()
                if let t = c.titlesChange, t > 0 { Text("· \(t) titles change") }
                if let m = c.missing, !m.isEmpty { Text("· \(m.count) missing").foregroundStyle(.orange) }
                if let e = c.extra, !e.isEmpty { Text("· \(e.count) extra").foregroundStyle(.orange) }
                Spacer()
                if let u = c.url, let url = URL(string: u) { Button("Open", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }.buttonStyle(.link) }
            }
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array((c.tracks ?? []).enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: t.matched == false ? "questionmark.circle" : "checkmark.circle.fill").foregroundStyle(t.matched == false ? Color.orange : Color.green).frame(width: 18)
                        Text(t.file ?? "").lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(t.newTitle ?? t.title ?? "").lineLimit(1).fontWeight(t.title != t.newTitle ? .semibold : .regular).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            if let p = c.penalties, !p.isEmpty {
                Text(p.map { "\($0.name) \($0.value?.text ?? "")" }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
            names(for: c.needs ?? [], context: c.id)
            Button("Accept Match") { Task { await accept(c) } }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !namesFilled(c.needs ?? [], context: c.id))
        }
    }

    // MARK: as is

    private var asis: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import As-Is").font(.title3.weight(.semibold))
            if let t = album?.target { Label(t, systemImage: "folder").foregroundStyle(.secondary) }
            names(for: album?.needsAsis ?? [], context: "asis")
            Button("Import As-Is") { Task { await importAsIs() } }
                .disabled(busy || album == nil || !namesFilled(album?.needsAsis ?? [], context: "asis"))
        }
    }

    // English spellings for names the files or the release give in other scripts
    @ViewBuilder private func names(for needs: [Api.NameRef], context: String) -> some View {
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(needs, id: \.name) { n in
                    HStack {
                        Text(n.kind.capitalized).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Text(n.name).frame(minWidth: 120, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        TextField("English", text: binding(context, n)).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private func binding(_ context: String, _ n: Api.NameRef) -> Binding<String> {
        let key = context + "|" + n.kind
        return Binding(get: { english[key] ?? n.suggest ?? "" }, set: { english[key] = $0 })
    }

    private func englishDict(_ needs: [Api.NameRef], context: String) -> [String: String] {
        var out: [String: String] = [:]
        for n in needs { out[n.kind] = english[context + "|" + n.kind] ?? n.suggest ?? "" }
        return out
    }

    private func namesFilled(_ needs: [Api.NameRef], context: String) -> Bool {
        englishDict(needs, context: context).allSatisfy { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: tracks

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array((album?.tracks ?? []).enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider() }
                    HStack {
                        Text(t.n.map(String.init) ?? "").foregroundStyle(.secondary).monospacedDigit().frame(width: 26, alignment: .trailing)
                        Text(t.title).lineLimit(1)
                        Spacer()
                        Text(t.file).font(.callout).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .trailing)
                        if let d = t.duration { Text(Fmt.clock(Int(d))).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: calls

    private func load() async {
        guard let panel = Config.panel, let ids = need.importIDs else { return }
        do {
            album = try await panel.inbox(ids.fid, ids.gid)
            error = nil
        } catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription; return }
        await poll { try await panel.candidates(ids.fid, ids.gid) }
    }

    private func search() async {
        guard let panel = Config.panel, let ids = need.importIDs, !query.isEmpty else { return }
        await poll { try await panel.searchCandidates(ids.fid, ids.gid, query) }
    }

    /// A lookup takes a while on the panel: ask again until it is done.
    private func poll(_ first: @escaping () async throws -> Api.Candidates) async {
        guard let panel = Config.panel, let ids = need.importIDs else { return }
        do {
            var c = try await first()
            cands = c
            var n = 0
            while c.running, n < 90 {
                try await Task.sleep(for: .seconds(2))
                c = try await panel.candidates(ids.fid, ids.gid)
                cands = c
                n += 1
            }
            if chosen == nil || candidate == nil { chosen = c.candidates?.first?.id }
        } catch is CancellationError {} catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription }
    }

    private func accept(_ c: Api.Candidate) async {
        guard let panel = Config.panel, let ids = need.importIDs else { return }
        error = nil
        do {
            let id = try await panel.apply(ids.fid, ids.gid, candidate: c.id, english: englishDict(c.needs ?? [], context: c.id))
            follow(id)
        } catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription }
    }

    private func importAsIs() async {
        guard let panel = Config.panel, let ids = need.importIDs else { return }
        error = nil
        do {
            let r = try await panel.asis(ids.fid, ids.gid, english: englishDict(album?.needsAsis ?? [], context: "asis"))
            follow(r.job)
        } catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription }
    }

    private func follow(_ id: Int) {
        job.follow(id) { _ in
            Task { await NeedsStore.shared.load() }
        }
    }
}

struct CandidateRow: View {
    let c: Api.Candidate
    let chosen: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.heading).lineLimit(1)
                    Text(c.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(Int((c.score * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: Color { c.quality == "good" ? .green : c.quality == "ok" ? .orange : .red }
}

/// A running or finished panel job: its state, what it did, and its log.
struct JobCard: View {
    let follower: JobFollower

    var body: some View {
        if let j = follower.job {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if j.running { ProgressView().controlSize(.small) }
                    else { Image(systemName: j.done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(j.done ? Color.green : Color.red) }
                    Text(j.title).font(.headline).lineLimit(1)
                    Spacer()
                    if !j.running, let run = j.run, let panel = Config.panel {
                        Button("Undo…") { NSWorkspace.shared.open(panel.url("/history", query: [URLQueryItem(name: "run", value: run)])) }.buttonStyle(.link)
                    }
                }
                if let p = j.progress, j.running { ProgressView(value: p) }
                ForEach(follower.lines, id: \.self) { Text($0).foregroundStyle(.secondary) }
                if let e = j.error { Text(e).foregroundStyle(.red) }
                if j.running, !j.log.isEmpty { Text(j.log.split(separator: "\n").suffix(4).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: names not in Latin letters

struct NamesView: View {
    @State private var names: [Api.NameNeed] = []
    @State private var english: [String: String] = [:]
    @State private var on: Set<String> = []
    @State private var loaded = false
    @State private var error: String?
    @State private var job = JobFollower()

    private var picked: [[String: String]] {
        names.compactMap { n in
            let e = (english[n.id] ?? n.suggest ?? "").trimmingCharacters(in: .whitespaces)
            return on.contains(n.id) && !e.isEmpty ? ["kind": n.kind, "name": n.name, "english": e] : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Names").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Rename \(picked.count)") { Task { await rename() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked.isEmpty || job.running)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if job.job != nil { JobCard(follower: job) }
                VStack(spacing: 0) {
                    ForEach(Array(names.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { on.contains(n.id) }, set: { if $0 { on.insert(n.id) } else { on.remove(n.id) } })).labelsHidden()
                            Text(n.kind.capitalized).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                            Text(n.name).frame(minWidth: 140, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            TextField("English", text: Binding(get: { english[n.id] ?? n.suggest ?? "" }, set: { english[n.id] = $0 })).textFieldStyle(.roundedBorder)
                            Text("\(n.albums?.count ?? 0)").foregroundStyle(.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
        }
        .task {
            guard let panel = Config.panel else { return }
            do {
                names = try await panel.names()
                on = Set(names.filter { !($0.suggest ?? "").isEmpty }.map(\.id))
                loaded = true
            } catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription }
        }
    }

    private func rename() async {
        guard let panel = Config.panel else { return }
        error = nil
        do {
            let id = try await panel.rename(picked)
            job.follow(id) { _ in Task { await NeedsStore.shared.load() } }
        } catch { self.error = (error as? PanelError)?.label ?? error.localizedDescription }
    }
}

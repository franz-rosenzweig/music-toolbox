import SwiftUI
import AppKit

@Observable @MainActor
final class HistoryStore {
    var runs: [Api.Run] = []
    var total = 0
    var next: String?
    var q = ""
    var who: String?
    var kind: String?
    var loading = false
    var error: String?

    func reload() async {
        guard let panel = Config.panel else { return }
        loading = true
        defer { loading = false }
        do {
            let h = try await panel.history(q: q, who: who, kind: kind)
            runs = h.runs; total = h.total; next = h.next; error = nil
        } catch is CancellationError {} catch { self.error = DeviceSession.describe(error) }
    }

    func more() async {
        guard let panel = Config.panel, let before = next else { return }
        loading = true
        defer { loading = false }
        if let h = try? await panel.history(q: q, who: who, kind: kind, before: before) {
            runs += h.runs; next = h.next; total = h.total
        }
    }

    var days: [(day: String, runs: [Api.Run])] {
        var out: [(String, [Api.Run])] = []
        for r in runs {
            let d = r.day ?? String(r.when.prefix(10))
            if let i = out.indices.last, out[i].0 == d { out[i].1.append(r) } else { out.append((d, [r])) }
        }
        return out
    }
}

/// Every change, newest first, with an undo that says what it would do first.
struct HistoryView: View {
    @State private var store = HistoryStore()
    @State private var selection: String?
    @State private var search = ""

    private var selected: Api.Run? { store.runs.first { $0.id == selection } ?? store.runs.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Who", selection: $store.who) {
                            Text("Anyone").tag(String?.none)
                            Text("Automatic").tag(String?.some("auto"))
                            Text("By hand").tag(String?.some("hand"))
                        }
                        Picker("Kind", selection: $store.kind) {
                            Text("Everything").tag(String?.none)
                            ForEach([("tags", "Tags and names"), ("lyrics", "Lyrics"), ("covers", "Covers"), ("imports", "Imports"), ("audio", "Audio")], id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                        }
                    }
                    .labelsHidden()
                }
                .padding(12)
                List(selection: $selection) {
                    ForEach(store.days, id: \.day) { d in
                        Section(d.day) { ForEach(d.runs) { RunRow(run: $0).tag($0.id) } }
                    }
                    if store.next != nil { Button("More") { Task { await store.more() } }.buttonStyle(.link) }
                }
            }
            .frame(width: 360)
            Divider()
            Group {
                if let r = selected { RunView(run: r) { Task { await store.reload() } }.id(r.id) }
                else if store.loading { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("History")
        .overlay(alignment: .top) {
            if let e = store.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8) }
        }
        .task { await store.reload() }
        .task(id: search) {
            if store.q != search { try? await Task.sleep(for: .milliseconds(300)); store.q = search; await store.reload() }
        }
        .onChange(of: store.who) { Task { await store.reload() } }
        .onChange(of: store.kind) { Task { await store.reload() } }
    }
}

struct RunRow: View {
    let run: Api.Run

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.icon(run.kind)).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).lineLimit(1)
                Text(run.summary ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(run.time).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if run.undone { Text("Undone").font(.caption).foregroundStyle(.orange) }
                else if !run.canUndo { Text("—").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 2)
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "lyrics": "text.quote"
        case "covers": "photo"
        case "imports": "square.and.arrow.down"
        case "audio": "waveform"
        default: "tag"
        }
    }
}

struct RunView: View {
    let run: Api.Run
    var changed: () -> Void

    @State private var preview: Api.UndoPreview?
    @State private var detail: Api.RunDetail?
    @State private var changes: [Api.FileChange] = []
    @State private var job = JobFollower()
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.title2.weight(.semibold))
                    Text([run.summary, run.when.replacingOccurrences(of: "T", with: " ")].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    if run.external { Text("Imported by beets itself: not in the change log").font(.callout).foregroundStyle(.orange) }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if job.job != nil { JobCard(follower: job) }
                undo
                if !changes.isEmpty { changesList }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: run.id) { await load() }
    }

    @ViewBuilder private var undo: some View {
        if run.undone {
            Label("Undone" + (run.undoneBy.map { " · \($0)" } ?? ""), systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        } else if let p = preview {
            VStack(alignment: .leading, spacing: 10) {
                if p.canUndo {
                    Text(p.labels.joined(separator: " · ")).foregroundStyle(.secondary)
                    if let later = p.laterRuns, !later.isEmpty {
                        Label("Later runs touched the same files: \(later.map(\.run).joined(separator: ", "))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let c = p.conflicts, !c.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(c.prefix(6).enumerated()), id: \.offset) { _, x in
                                Text("\(x.field): now “\(x.now?.text ?? "")”, would restore “\(x.wouldRestore?.text ?? "")”").font(.callout).foregroundStyle(.orange).lineLimit(1)
                            }
                            if c.count > 6 { Text("+ \(c.count - 6)").foregroundStyle(.secondary) }
                        }
                    }
                    HStack {
                        Button(p.safe == false ? "Undo Anyway" : "Undo", role: p.safe == false ? .destructive : nil) { Task { await doUndo(force: p.safe == false) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(job.running)
                    }
                } else {
                    Text(p.reason ?? "This run can’t be undone here").foregroundStyle(.secondary)
                }
            }
        } else if run.canUndo {
            ProgressView().controlSize(.small)
        }
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes · \(detail?.total ?? changes.count)").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.offset) { i, f in
                    if i > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.path).lineLimit(1).truncationMode(.middle)
                        ForEach(Array(f.rows.enumerated()), id: \.offset) { _, r in
                            HStack(spacing: 6) {
                                Text(Self.fieldLabel(r.field)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                if let n = r.name { Text(n).lineLimit(1) }
                                Text(r.before?.text ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(r.after?.text ?? "").lineLimit(1)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            if let n = detail?.nextOffset { Button("More") { Task { await more(n) } }.buttonStyle(.link) }
        }
    }

    static func fieldLabel(_ f: String) -> String {
        switch f { case "file_created": "Added"; case "file_replaced": "Replaced"; case "file_removed": "Removed"; case "canonical_name": "English name"; case "vorbis:ALBUMARTIST": "Album artist"; default: f }
    }

    private func load() async {
        guard let panel = Config.panel else { return }
        async let d = try? panel.run(run.run)
        if run.canUndo && !run.undone { preview = try? await panel.undoPreview(run.run) }
        if let d = await d { detail = d; changes = d.changes }
    }

    private func more(_ offset: Int) async {
        guard let panel = Config.panel, let d = try? await panel.run(run.run, offset: offset) else { return }
        detail = d
        changes += d.changes
    }

    private func doUndo(force: Bool) async {
        guard let panel = Config.panel else { return }
        error = nil
        do {
            let id = try await panel.undo(run.run, force: force)
            job.follow(id) { j in
                if !j.done { error = j.error }
                changed()
            }
        } catch { self.error = DeviceSession.describe(error) }
    }
}

// MARK: Activity

struct ActivityView: View {
    @State private var jobs: [Api.Job] = []
    @State private var selection: Int?
    @State private var error: String?

    private var selected: Api.Job? { jobs.first { $0.id == selection } ?? jobs.first }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(jobs, id: \.id) { j in
                    HStack(spacing: 10) {
                        Group {
                            if j.running { ProgressView().controlSize(.small) }
                            else { Image(systemName: j.done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(j.done ? Color.green : Color.red) }
                        }
                        .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(j.title).lineLimit(1)
                            Text(j.kind).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .tag(j.id)
                }
            }
            .frame(width: 360)
            Divider()
            Group {
                if let j = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(j.title).font(.title2.weight(.semibold))
                            Text([j.status.capitalized, j.progress.map { "\(Int($0 * 100))%" }].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            if let e = j.error { Text(e).foregroundStyle(.red) }
                            if let run = j.run, let panel = Config.panel {
                                Button("Undo…") { NSWorkspace.shared.open(panel.url("/history", query: [URLQueryItem(name: "run", value: run)])) }.buttonStyle(.link)
                            }
                            if !j.log.isEmpty { Text(j.log).font(.system(.callout, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Activity")
        .overlay(alignment: .top) {
            if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8) }
        }
        .task {
            while !Task.isCancelled {
                if let panel = Config.panel {
                    do { jobs = try await panel.recentJobs(40); error = nil } catch is CancellationError {} catch { self.error = DeviceSession.describe(error) }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

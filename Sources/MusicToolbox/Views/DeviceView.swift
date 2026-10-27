import SwiftUI

struct DeviceView: View {
    @Bindable var session: DeviceSession
    @State private var store = DeviceStore.shared

    private var v: Volume { session.volume }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if session.activity == .copying { progress }
                if let d = session.dryRun { dryRun(d) }
                if session.profile.canFix || session.issues != nil { issuesSection }
                if session.profile.hasQueue { queue }
                if let n = session.newAlbums, !n.albums.isEmpty { added(n) }
                history
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(v.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(session.profile.hasQueue ? "Copy Queue" : "Copy Everything", systemImage: "arrow.down.to.line") {
                    if session.profile.hasQueue { session.copyQueue() } else { session.copyEverything() }
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(session.busy || (session.profile.hasQueue && session.items.allSatisfy(\.missing)))
                Menu("More", systemImage: "ellipsis.circle") {
                    if session.profile.hasQueue { Button("Copy Everything") { session.copyEverything() } }
                    Button("Mirror…") { session.planMirror() }
                    Button("Check") { session.check() }
                    Divider()
                    Button("Reload Queue") { session.load() }
                    Button("Eject") { Task { await session.eject() } }
                }
                .disabled(session.busy)
            }
        }
        .task(id: v.id) { session.load() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.title).font(.system(size: 26, weight: .semibold))
                    Menu(v.profile.name) {
                        ForEach(DeviceProfile.builtIn) { p in
                            Button(p.name) { Task { try? await store.setProfile(v, p) } }
                        }
                    }
                    .menuStyle(.button).buttonStyle(.bordered).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: v.total > 0 ? Double(v.total - v.free) / Double(v.total) : 0)
                HStack {
                    Text("\(Fmt.size(v.free)) free")
                    Spacer()
                    if let d = session.onDevice { Text("\(Fmt.size(d)) of music") }
                    Text(Fmt.size(v.total))
                }
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if !v.profile.limits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(v.profile.limits, id: \.self) { Text($0).font(.callout).padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary, in: Capsule()) }
                }
            }
        }
    }

    // MARK: issues

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Issues").font(.title3.weight(.semibold))
                Spacer()
                if let i = session.issues {
                    if i.total == 0 { Label("None · \(i.checked.formatted()) checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon) }
                    else {
                        Text(i.counts.sorted { $0.key < $1.key }.map { "\(Api.Issues.label($0.key)) \($0.value)" }.joined(separator: " · "))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if session.activity == .fixing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Fixing").font(.headline); Spacer() }
                    if let f = session.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            }
            if let n = session.fixed {
                HStack(spacing: 8) {
                    Label("\(n) fixed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if let run = session.fixRun { UndoControl(run: run) { session.load() } }
                }
            }
            if let i = session.issues, i.total > 0 {
                VStack(spacing: 0) {
                    ForEach(Array(i.issues.enumerated()), id: \.element.id) { n, issue in
                        if n > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((issue.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(issue.path.split(separator: "/").dropLast().joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(issue.checkLabel) \(issue.value?.text ?? "") > \(issue.limit?.text ?? "")").font(.callout).foregroundStyle(.orange).monospacedDigit()
                            Button("Play", systemImage: "play.fill") { Player.shared.play(path: issue.path) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                if i.total > i.issues.count { Text("+ \(i.total - i.issues.count)").foregroundStyle(.secondary) }
                if i.fixable > 0 {
                    Button("Fix \(i.fixable)") { session.fix() }.buttonStyle(.borderedProminent).disabled(session.busy)
                }
            }
        }
    }

    // MARK: queue

    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue").font(.title3.weight(.semibold))
                Spacer()
                if session.activity == .loading { ProgressView().controlSize(.small) }
                else { Text("\(session.items.count) · \(Fmt.size(session.queueBytes))").foregroundStyle(.secondary).monospacedDigit() }
            }
            if session.items.isEmpty {
                if session.activity != .loading {
                    Text("Empty").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 46) }
                        row(item)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func row(_ item: DeviceSession.Item) -> some View {
        HStack(spacing: 12) {
            Group {
                if item.missing { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                else {
                    switch item.state {
                    case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                    case .copying: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if !item.missing, item.albumID != nil || item.kind == "track" {
                Button("Play", systemImage: "play.fill") {
                    if item.kind == "track" { Player.shared.play(path: item.entry) } else if let id = item.albumID { Player.shared.play(albumID: id) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if !item.missing { Text(Fmt.size(item.size)).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
            if item.state == .waiting || item.state == .failed {
                Button("Remove from Queue", systemImage: "xmark") { session.removeFromQueue(item) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(session.busy)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: running

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label(session.mode)).font(.headline)
                Text(session.current).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { session.cancel() }
            }
            if let f = session.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            HStack(spacing: 6) {
                if session.bytesTotal > 0 { Text("\(Fmt.size(session.bytesDone)) of \(Fmt.size(session.bytesTotal))") }
                if session.rate > 0 { Text("· \(Fmt.rate(session.rate))") }
                if let l = session.left { Text("· \(Fmt.left(l))") }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func label(_ m: DeviceSession.Mode?) -> String {
        switch m { case .queue: "Queue"; case .all: "Everything"; case .mirror: "Mirror"; case nil: "" }
    }

    private func dryRun(_ d: DeviceSession.DryRun) -> some View {
        let mirror = session.dryRunMode == .mirror
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(mirror ? "Mirror" : "Check").font(.headline)
                Spacer()
                Button("Close") { session.dismissPlan() }
            }
            HStack(spacing: 6) {
                Text("\(d.new) new")
                Text("· \(d.changed) changed")
                Text("· \(d.timeOnly) time only")
                if mirror {
                    Text("· \(d.staleCount) to remove").foregroundStyle(d.staleCount > 0 ? .orange : .secondary)
                    Text("· \(d.junk) macOS files")
                }
            }
            .foregroundStyle(.secondary).monospacedDigit()
            if mirror && !d.stale.isEmpty {
                VStack(spacing: 0) {
                    ForEach(d.stale.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }).prefix(40), id: \.key) { k, n in
                        HStack { Image(systemName: "minus.circle").foregroundStyle(.orange); Text(k).lineLimit(1); Spacer(); Text("\(n)").foregroundStyle(.secondary) }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            if mirror {
                Button("Mirror", role: .destructive) { session.confirmMirror() }.buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func added(_ n: Api.NewAlbums) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Added Since the Last Copy").font(.title3.weight(.semibold))
                Spacer()
                Text("\(n.albums.count)").foregroundStyle(.secondary).monospacedDigit()
                Button("Queue \(n.albums.count)") { session.queueNewAlbums() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            VStack(spacing: 0) {
                ForEach(Array(n.albums.prefix(12).enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider() }
                    HStack(spacing: 12) {
                        CoverView(albumID: a.hasCover ? a.id : nil, size: 32)
                        VStack(alignment: .leading, spacing: 1) { Text(a.album).lineLimit(1); Text(a.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(Fmt.size(a.bytes)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            if n.albums.count > 12 { Text("+ \(n.albums.count - 12)").foregroundStyle(.secondary) }
        }
    }

    /// The panel's copy history, which includes this app's copies (it reports each one).
    @ViewBuilder private var history: some View {
        let rows = session.syncs?.syncs ?? []
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Copies").font(.title3.weight(.semibold))
                    Spacer()
                    if let l = session.syncs?.lastFinished { Text("Last \(l.time)").foregroundStyle(.secondary).monospacedDigit() }
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(12).enumerated()), id: \.element.id) { i, h in
                        if i > 0 { Divider() }
                        HStack(spacing: 8) {
                            Image(systemName: h.result == "finished" ? "checkmark.circle.fill" : h.result == "cancelled" ? "stop.circle" : "xmark.circle.fill")
                                .foregroundStyle(h.result == "finished" ? .green : h.result == "cancelled" ? .secondary : .red)
                            Text(Self.mode(h.mode))
                            if let n = h.copied { Text("· \(n) copied").foregroundStyle(.secondary) }
                            if let n = h.removed, n > 0 { Text("· \(n) removed").foregroundStyle(.secondary) }
                            if let s = h.seconds { Text("· \(Fmt.clock(s))").foregroundStyle(.secondary) }
                            Spacer()
                            Text(h.time).foregroundStyle(.secondary)
                        }
                        .monospacedDigit().padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    static func mode(_ m: String?) -> String {
        switch m { case "queue": "Queue"; case "all": "Everything"; case "mirror": "Mirror"; case "wipe": "Wipe"; default: m ?? "" }
    }
}

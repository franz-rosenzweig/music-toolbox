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
                queue
                if !session.history.isEmpty { history }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(v.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy Queue", systemImage: "arrow.down.to.line") { session.copyQueue() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.busy || session.items.allSatisfy(\.missing))
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Copy Everything") { session.copyEverything() }
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
            if item.missing {
                Button("Remove", systemImage: "xmark") { session.removeFromQueue(item) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            } else {
                Text(Fmt.size(item.size)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
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

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(session.history.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { Divider() }
                    HStack(spacing: 8) {
                        Image(systemName: h.result == "finished" ? "checkmark.circle.fill" : h.result == "cancelled" ? "stop.circle" : "xmark.circle.fill")
                            .foregroundStyle(h.result == "finished" ? .green : h.result == "cancelled" ? .secondary : .red)
                        Text(label(h.mode))
                        Text("· \(h.copied) copied").foregroundStyle(.secondary)
                        if h.removed > 0 { Text("· \(h.removed) removed").foregroundStyle(.secondary) }
                        Text("· \(Fmt.clock(h.seconds))").foregroundStyle(.secondary)
                        Spacer()
                        Text(h.date, style: .time).foregroundStyle(.secondary)
                    }
                    .monospacedDigit().padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

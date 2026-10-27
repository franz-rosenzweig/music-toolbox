import SwiftUI
import AppKit

struct UploadView: View {
    @State private var store = UploadStore.shared
    @State private var nav = Nav.shared
    @State private var targeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.staged.isEmpty && store.jobs.isEmpty && !store.scanning {
                    Picker.empty(choose: choose)
                } else {
                    if !store.staged.isEmpty || store.scanning { staged }
                    ForEach(store.jobs) { JobRow(job: $0) }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.add(urls) }
            return true
        } isTargeted: { targeted = $0 }
        .navigationTitle("Upload")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Folders…", systemImage: "folder") { choose(folders: true) }
                    Button("Files…", systemImage: "music.note") { choose(folders: false) }
                }
            }
        }
        .onChange(of: nav.choose) { _, go in
            if go { nav.choose = false; choose(folders: true) }
        }
    }

    private func choose(folders: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = folders
        p.canChooseFiles = !folders
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        Task { await store.add(p.urls) }
    }

    private var staged: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Folder name", text: $store.name)
                    .textFieldStyle(.roundedBorder)
                Button("Upload") { store.upload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.staged.isEmpty || store.scanning)
                Button("Clear") { store.clear() }
            }
            HStack(spacing: 8) {
                if store.scanning { ProgressView().controlSize(.small) }
                Text("\(store.staged.count) files · \(Fmt.size(store.stagedBytes))")
                if store.folders.filter({ !$0.name.isEmpty }).count > 1 { Text("· \(store.folders.count) folders") }
            }
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(store.folders.enumerated()), id: \.offset) { i, f in
                    if i > 0 { Divider() }
                    HStack {
                        Image(systemName: f.name.isEmpty ? "music.note" : "folder").foregroundStyle(.secondary).frame(width: 22)
                        Text(f.name.isEmpty ? "Files" : f.name).lineLimit(1)
                        Spacer()
                        Text("\(f.count)").foregroundStyle(.secondary)
                        Text(Fmt.size(f.size)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private enum Picker {
    @MainActor
    static func empty(choose: @escaping (Bool) -> Void) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
            HStack {
                Button("Folders…") { choose(true) }.buttonStyle(.borderedProminent)
                Button("Files…") { choose(false) }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

struct JobRow: View {
    let job: UploadJob
    @State private var store = UploadStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon
                Text(job.name).font(.headline).lineLimit(1)
                Spacer()
                actions
            }
            switch job.state {
            case .sending, .paused, .queued:
                ProgressView(value: job.fraction)
                HStack(spacing: 6) {
                    Text("\(Fmt.size(job.sent)) of \(Fmt.size(job.total))")
                    if job.state == .sending, job.rate > 0 { Text("· \(Fmt.rate(job.rate))") }
                    if let l = job.left { Text("· \(Fmt.left(l))") }
                    if job.state == .paused { Text("· Paused") }
                    if job.state == .queued { Text("· Waiting") }
                    if !job.note.isEmpty { Text("· \(job.note)").foregroundStyle(.orange) }
                }
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            case .importing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Importing").foregroundStyle(.secondary) }
            case .done:
                HStack(spacing: 6) {
                    Text("\(job.imported ?? 0) imported")
                    if let n = job.needLook, n > 0 {
                        Button("\(n) need a look") { Nav.shared.place = .needs }.buttonStyle(.link).foregroundStyle(.orange)
                    }
                    Text("· \(Fmt.size(job.total))")
                }
                .font(.callout).foregroundStyle(.secondary)
            case .failed:
                Text(job.note.isEmpty ? "Failed" : job.note).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        default: Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .sending, .queued:
            Button("Pause", systemImage: "pause.fill") { store.pause(job) }.labelStyle(.iconOnly).buttonStyle(.borderless)
        case .paused, .failed:
            Button("Resume", systemImage: "play.fill") { store.resume(job) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            Button("Discard", systemImage: "xmark") { store.discard(job) }.labelStyle(.iconOnly).buttonStyle(.borderless)
        case .done:
            Button("Dismiss", systemImage: "xmark") { store.remove(job) }.labelStyle(.iconOnly).buttonStyle(.borderless)
        case .importing: EmptyView()
        }
    }
}

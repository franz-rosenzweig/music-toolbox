import SwiftUI

struct RootView: View {
    @State private var nav = Nav.shared
    @State private var store = DeviceStore.shared
    @State private var uploads = UploadStore.shared
    @State private var needs = NeedsStore.shared
    @AppStorage("panelURL") private var panelURL = ""
    @AppStorage("panelUser") private var panelUser = ""

    /// Reads the stored address and user (so the view follows Connect), or the environment's.
    private var configured: Bool {
        _ = (panelURL, panelUser)
        return Config.panelURL != nil && !Config.user.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.place) {
                Label("Needs You", systemImage: "tray")
                    .badge(needs.open)
                    .tag(Place.needs)
                Label("Upload", systemImage: "arrow.up.circle")
                    .badge(uploads.jobs.filter { $0.state != .done }.count)
                    .tag(Place.upload)
                Label("Library", systemImage: "magnifyingglass").tag(Place.library)
                Label("Rip", systemImage: "opticaldisc").tag(Place.rip)
                Label("History", systemImage: "clock.arrow.circlepath").tag(Place.history)
                Label("Activity", systemImage: "list.bullet.rectangle").tag(Place.activity)
                Section("Devices") {
                    ForEach(store.devices) { v in
                        Label(v.title, systemImage: "sdcard")
                            .badge(nav.sessions[v.id]?.items.count ?? 0)
                            .tag(Place.device(v.id))
                    }
                    ForEach(store.candidates) { v in
                        Label(v.name, systemImage: "externaldrive")
                            .foregroundStyle(.secondary)
                            .tag(Place.setup(v.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            if !configured {
                SettingsForm(firstRun: true)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch nav.place {
                case .needs, nil: NeedsView()
                case .upload: UploadView()
                case .library: LibraryView()
                case .rip: RipView()
                case .history: HistoryView()
                case .activity: ActivityView()
                case .device(let id):
                    if let v = store.volumes.first(where: { $0.id == id }) { DeviceView(session: nav.session(for: v)) } else { Color.clear }
                case .setup(let id):
                    if let v = store.volumes.first(where: { $0.id == id }) { SetupView(volume: v) } else { Color.clear }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { PlayerBar() }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, Player.shared.track == nil ? 0 : 70) }
        .task {
            while !Task.isCancelled {
                await needs.load()
                try? await Task.sleep(for: .seconds(45))
            }
        }
        .onChange(of: store.volumes) { _, vols in
            if case .device(let id) = nav.place, !vols.contains(where: { $0.id == id }) { nav.place = .needs }
            if case .setup(let id) = nav.place, !vols.contains(where: { $0.id == id }) { nav.place = .needs }
        }
    }
}

/// An unmarked disk: which kind of device is it?
struct SetupView: View {
    let volume: Volume
    @State private var store = DeviceStore.shared
    @State private var nav = Nav.shared
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(volume.name).font(.title2.weight(.semibold))
            Text("\(Fmt.size(volume.free)) free of \(Fmt.size(volume.total))").foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(DeviceProfile.builtIn) { p in
                    Button(p.name) {
                        Task {
                            do { try await store.setUp(volume, profile: p); nav.place = .device(volume.id) } catch { failed = true }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(width: 220)
                }
            }
            if failed { Label("Can’t write to the disk", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(volume.name)
    }
}

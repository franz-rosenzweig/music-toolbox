import SwiftUI
import AppKit

/// An audio CD in the drive: what MusicBrainz says it is, ripped to FLAC, then sent to the server.
struct RipView: View {
    @Bindable private var ripper = Ripper.shared
    @AppStorage("ejectWhenDone") private var ejectWhenDone = true

    var body: some View {
        Group {
            if let disc = ripper.disc { content(disc) }
            else {
                Image(systemName: "opticaldisc").font(.system(size: 56, weight: .light)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Rip")
        .task { await ripper.scan() }
    }

    private func content(_ disc: Disc) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(disc)
                if let e = ripper.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                tracks
                actions
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ disc: Disc) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let c = ripper.cover, let img = NSImage(data: c) { Image(nsImage: img).resizable().scaledToFill() }
                else { Image(systemName: "opticaldisc").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
            }
            .frame(width: 128, height: 128).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Album", text: $ripper.album).textFieldStyle(.roundedBorder).font(.title3.weight(.semibold))
                HStack {
                    TextField("Artist", text: $ripper.albumArtist).textFieldStyle(.roundedBorder)
                    TextField("Year", text: $ripper.year).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                HStack(spacing: 8) {
                    Text("\(disc.tracks.count) tracks · \(Fmt.clock(Int(disc.totalSeconds)))").foregroundStyle(.secondary).monospacedDigit()
                    if ripper.activity == .looking { ProgressView().controlSize(.small) }
                    if ripper.releases.count > 1 {
                        Picker("Release", selection: Binding(get: { ripper.chosen }, set: { i in Task { await ripper.choose(i) } })) {
                            ForEach(Array(ripper.releases.enumerated()), id: \.offset) { i, r in Text(r.summary).tag(i) }
                        }
                        .labelsHidden().frame(maxWidth: 340)
                    } else if let r = ripper.release {
                        Text(r.summary).foregroundStyle(.secondary)
                    }
                    if ripper.releases.isEmpty && ripper.activity != .looking {
                        Button("Look Up Again", systemImage: "arrow.clockwise") { Task { await ripper.lookup() } }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var tracks: some View {
        VStack(spacing: 0) {
            ForEach(ripper.items) { it in
                if it.id != ripper.items.first?.id { Divider() }
                HStack(spacing: 12) {
                    Group {
                        switch it.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                        case .ripping: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                    .frame(width: 20)
                    Text("\(it.track.number)").foregroundStyle(.secondary).monospacedDigit().frame(width: 22, alignment: .trailing)
                    // the title is found by track each time it is read or written: the list can empty under this
                    // field (the disc is ejected), and an index into it would then be out of range
                    TextField("Title", text: Binding(
                        get: { ripper.items.first { $0.id == it.id }?.title ?? it.title },
                        set: { v in if let j = ripper.items.firstIndex(where: { $0.id == it.id }) { ripper.items[j].title = v } }
                    )).textFieldStyle(.plain)
                    Spacer()
                    if !it.artist.isEmpty, it.artist != ripper.albumArtist { Text(it.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Text(Fmt.clock(Int(it.track.seconds))).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ripper.activity == .ripping {
                ProgressView(value: ripper.fraction)
                HStack { Text("\(ripper.done) of \(ripper.items.count)").foregroundStyle(.secondary).monospacedDigit(); Spacer(); Button("Cancel") { ripper.cancel() } }
            } else {
                HStack {
                    Button("Rip and Upload") { ripper.rip(andUpload: true) }.buttonStyle(.borderedProminent).disabled(ripper.activity != .idle)
                    Button("Rip") { ripper.rip(andUpload: false) }.disabled(ripper.activity != .idle)
                    Toggle("Eject When Done", isOn: $ejectWhenDone).toggleStyle(.checkbox).padding(.leading, 8)
                    Spacer()
                    Button("Eject", systemImage: "eject") { Task { await ripper.eject() } }.disabled(ripper.activity == .ripping)
                }
            }
            if let f = ripper.folder, ripper.items.allSatisfy({ $0.state == .done }) {
                HStack(spacing: 8) {
                    Label((f.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }.buttonStyle(.link)
                }
            }
        }
    }
}

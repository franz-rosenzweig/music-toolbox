import SwiftUI
import AppKit

/// Finding a release on MusicBrainz by any of what is printed on it: fill in what you know.
struct ReleaseFinder: View {
    @State var fields: MBSearch.Fields
    var pick: (String) -> Void
    var close: () -> Void

    @State private var link = ""
    @State private var found: [MBSearch.Found] = []
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find on MusicBrainz").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { close() }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    TextField("Artist", text: $fields.artist)
                    TextField("Album", text: $fields.album)
                }
                GridRow {
                    TextField("Year", text: $fields.year)
                    TextField("Country", text: $fields.country)
                }
                GridRow {
                    TextField("Label", text: $fields.label)
                    TextField("Catalog number", text: $fields.catalog)
                }
                GridRow {
                    TextField("Barcode", text: $fields.barcode)
                    HStack {
                        TextField("Discs", text: $fields.discs)
                        TextField("Tracks", text: $fields.tracks)
                        TextField("Format", text: $fields.format)
                    }
                }
                GridRow {
                    TextField("MusicBrainz link", text: $link).gridCellColumns(2)
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Search") { Task { await search() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(searching || (fields.isEmpty && MBSearch.releaseID(in: link) == nil))
                if searching { ProgressView().controlSize(.small) }
                if searched && !searching { Text("\(found.count)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Text(MBSearch.query(fields)).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            List(found) { r in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([r.artist, r.title].filter { !$0.isEmpty }.joined(separator: " — ")).lineLimit(1)
                        Text([r.date, r.country, r.shape, r.barcode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        let lc = (r.labels + r.catalogs.prefix(2)).joined(separator: " · ")
                        if !lc.isEmpty || r.disambiguation != nil {
                            Text([r.disambiguation, lc.isEmpty ? nil : lc].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Open", systemImage: "arrow.up.right.square") { if let u = URL(string: r.link) { NSWorkspace.shared.open(u) } }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button("Use") { pick(r.link) }.buttonStyle(.bordered)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
        .padding(22)
        .frame(width: 680, height: 600)
    }

    private func search() async {
        if let id = MBSearch.releaseID(in: link) { pick("https://musicbrainz.org/release/\(id)"); return }
        searching = true
        defer { searching = false; searched = true }
        do { found = try await MBSearch.search(fields); error = nil } catch { self.error = (error as? RemoteError)?.detail ?? "Can’t reach MusicBrainz" }
    }
}

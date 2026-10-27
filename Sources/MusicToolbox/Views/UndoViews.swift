import SwiftUI

/// "Undo" for a change the panel logged: what it would do first, then do it.
struct UndoControl: View {
    @State private var model: UndoModel

    init(run: String, done: @escaping () -> Void = {}) {
        let m = UndoModel(run: run)
        m.onDone = done
        _model = State(initialValue: m)
    }

    var body: some View {
        switch model.phase {
        case .idle:
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.load() } }.buttonStyle(.link)
        case .loading:
            ProgressView().controlSize(.small)
        case .preview(let p):
            VStack(alignment: .leading, spacing: 8) {
                if p.canUndo {
                    Text(p.labels.joined(separator: " · ")).foregroundStyle(.secondary)
                    if let c = p.conflicts, !c.isEmpty {
                        Label("\(c.count) values changed since", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    HStack {
                        Button(p.safe == false ? "Undo Anyway" : "Undo", role: p.safe == false ? .destructive : nil) { Task { await model.confirm(force: p.safe == false) } }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { model.cancel() }
                    }
                } else {
                    Text(p.reason ?? "Can’t be undone here").foregroundStyle(.secondary)
                    Button("Close") { model.cancel() }.buttonStyle(.link)
                }
            }
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Undoing").foregroundStyle(.secondary) }
        case .finished:
            Label("Undone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m):
            HStack { Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange); Button("Close") { model.cancel() }.buttonStyle(.link) }
        }
    }
}

struct ToastView: View {
    @Bindable private var nav = Nav.shared

    var body: some View {
        if let t = nav.toast {
            HStack(spacing: 14) {
                Text(t.message)
                if let undo = t.undo {
                    Button("Undo") { nav.toast = nil; Task { await undo() } }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button { nav.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

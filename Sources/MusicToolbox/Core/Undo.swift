import Foundation
import Observation

/// Going back on a decision. A change the panel logged is undone as the History page undoes it: the
/// panel says first what it would do, then does it. A change the panel does not log (the queue, Later,
/// marking tracks instrumental) is put back by a toast with an Undo that does the opposite.
@Observable @MainActor
final class UndoModel {
    enum Phase { case idle, loading, preview(Api.UndoPreview), running, finished, failed(String) }

    let run: String
    var phase: Phase = .idle
    let follower = JobFollower()
    var onDone: () -> Void = {}

    init(run: String) { self.run = run }

    func load() async {
        guard let panel = Config.panel else { return }
        phase = .loading
        do { phase = .preview(try await panel.undoPreview(run)) } catch { phase = .failed(DeviceSession.describe(error)) }
    }

    func confirm(force: Bool) async {
        guard let panel = Config.panel else { return }
        phase = .running
        do {
            let id = try await panel.undo(run, force: force)
            follower.follow(id) { [self] j in
                phase = j.done ? .finished : .failed(j.error ?? "The undo stopped")
                onDone()
            }
        } catch { phase = .failed(DeviceSession.describe(error)) }
    }

    func cancel() { phase = .idle }
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: (@MainActor () async -> Void)?
}

extension Nav {
    /// Says what just happened, with an Undo for ten seconds when it can be put back.
    func notify(_ message: String, undo: (@MainActor () async -> Void)? = nil) {
        let t = Toast(message: message, undo: undo)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(10))
            if toast?.id == t.id { toast = nil }
        }
    }
}

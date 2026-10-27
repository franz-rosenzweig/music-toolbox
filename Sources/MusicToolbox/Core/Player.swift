import AVFoundation
import AppKit
import Observation

/// Plays one track from the library, so you know what it is. Nothing more: no queue, no next.
@Observable @MainActor
final class Player {
    static let shared = Player()

    var track: Api.Track?
    var playing = false
    var failed = false
    var time: Double = 0
    var duration: Double = 0

    let player = AVPlayer()
    private var status: NSKeyValueObservation?
    private var ticker: Any?

    init() {
        ticker = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.playing = self.player.timeControlStatus != .paused
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
    }

    func play(_ t: Api.Track) {
        guard let panel = Config.panel else { return }
        let asset = AVURLAsset(url: panel.streamURL(t.id), options: ["AVURLAssetHTTPHeaderFieldsKey": panel.headers])
        let item = AVPlayerItem(asset: asset)
        status = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in if item.status == .failed { self?.failed = true; self?.playing = false } }
        }
        track = t
        failed = false
        time = 0
        duration = t.duration ?? 0
        player.replaceCurrentItem(with: item)
        player.play()
        playing = true
    }

    /// The first track of an album.
    func play(albumID: String) {
        guard let panel = Config.panel else { return }
        Task { if let a = try? await panel.album(albumID), let t = a.tracks.first { play(t) } }
    }

    func play(path: String) {
        guard let panel = Config.panel else { return }
        Task { if let t = try? await panel.track(path: path) { play(t) } }
    }

    func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        playing = player.timeControlStatus != .paused
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        time = seconds
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        track = nil
        playing = false
    }
}

/// Covers come through the panel's login, so they are fetched here and kept.
@MainActor
enum Covers {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ id: String, size: Int = 128) async -> NSImage? {
        let key = "\(id)-\(size)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let panel = Config.panel, let data = await panel.cover(id, size: size), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

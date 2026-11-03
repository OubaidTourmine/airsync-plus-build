import AppKit
import Foundation
import MediaPlayer

// Lightweight native MediaPlayer bridge hosted inside the existing JVM process.
// No SwiftUI, status-bar item, popover or second music player.
public typealias CommandCallback = @convention(c) (Int32, Double) -> Void

@MainActor
private final class BitChordGlassBridge: NSObject {
    static let shared = BitChordGlassBridge()

    var title: String = "Nothing playing"
    var artist: String = "BitChord"
    var duration: Double = 0
    var elapsed: Double = 0
    var isPlaying: Bool = false
    var artwork: NSImage?

    var callback: CommandCallback?
    private var currentArtworkURL = ""
    private var initialized = false

    func start(_ handler: CommandCallback?) {
        callback = handler
        guard !initialized else { return }
        initialized = true
        registerMediaCommands()
    }

    func stop() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        callback = nil
    }

    func emit(_ code: Int32, _ value: Double = 0) {
        callback?(code, value)
    }

    func update(title newTitle: String, artist newArtist: String, artworkURL: String,
                duration newDuration: Double, elapsed newElapsed: Double, playing: Bool) {
        title = newTitle.isEmpty ? "Nothing playing" : newTitle
        artist = newArtist
        duration = max(0, newDuration)
        elapsed = max(0, min(newElapsed, max(0, newDuration)))
        isPlaying = playing
        if currentArtworkURL != artworkURL {
            currentArtworkURL = artworkURL
            artwork = nil
            if let url = URL(string: artworkURL), url.scheme == "https" {
                let identity = artworkURL
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard self.currentArtworkURL == identity else { return }
                        self.artwork = image
                        self.publishNowPlaying()
                    }
                }.resume()
            }
        }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard title != "Nothing playing" else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func registerMediaCommands() {
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.isEnabled = true
        remote.pauseCommand.isEnabled = true
        remote.togglePlayPauseCommand.isEnabled = true
        remote.nextTrackCommand.isEnabled = true
        remote.previousTrackCommand.isEnabled = true
        remote.changePlaybackPositionCommand.isEnabled = true
        remote.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.emit(1) }
            return .success
        }
        remote.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.emit(2) }
            return .success
        }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.emit(3) }
            return .success
        }
        remote.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.emit(4) }
            return .success
        }
        remote.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.emit(5) }
            return .success
        }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let change = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async { self?.emit(9, change.positionTime) }
            return .success
        }
    }
}

@_cdecl("bc_start")
public func bc_start(_ callback: CommandCallback?) {
    DispatchQueue.main.async { BitChordGlassBridge.shared.start(callback) }
}

@_cdecl("bc_update")
public func bc_update(_ title: UnsafePointer<CChar>?, _ artist: UnsafePointer<CChar>?,
                      _ artworkURL: UnsafePointer<CChar>?, _ duration: Double,
                      _ elapsed: Double, _ playing: Int32) {
    let t = title.map { String(cString: $0) } ?? ""
    let a = artist.map { String(cString: $0) } ?? ""
    let url = artworkURL.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        BitChordGlassBridge.shared.update(title: t, artist: a, artworkURL: url,
                                          duration: duration, elapsed: elapsed, playing: playing != 0)
    }
}

@_cdecl("bc_stop")
public func bc_stop() {
    DispatchQueue.main.async { BitChordGlassBridge.shared.stop() }
}

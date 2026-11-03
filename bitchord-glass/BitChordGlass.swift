import AppKit
import Combine
import Foundation
import MediaPlayer
import SwiftUI

// Native bridge hosted inside the existing JVM process, not a second app.
public typealias CommandCallback = @convention(c) (Int32, Double) -> Void

@MainActor
private final class BitChordGlassBridge: NSObject, ObservableObject {
    static let shared = BitChordGlassBridge()

    @Published var title: String = "Nothing playing"
    @Published var artist: String = "BitChord"
    @Published var duration: Double = 0
    @Published var elapsed: Double = 0
    @Published var isPlaying: Bool = false
    @Published var artwork: NSImage?

    var callback: CommandCallback?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var currentArtworkURL = ""
    private var initialized = false

    func start(_ handler: CommandCallback?) {
        callback = handler
        guard !initialized else { return }
        initialized = true
        registerMediaCommands()
    }

    func stop() {
        hideTray()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        callback = nil
    }

    func emit(_ code: Int32, _ value: Double = 0) {
        callback?(code, value)
    }

    func showTray() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let appIcon = NSApplication.shared.applicationIconImage {
                let icon = (appIcon.copy() as? NSImage) ?? appIcon
                icon.size = NSSize(width: 19, height: 19)
                icon.isTemplate = false
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "BitChord")
            }
            button.imagePosition = .imageOnly
            button.toolTip = "BitChord · Mini Player"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let pane = NSPopover()
        pane.behavior = .transient
        pane.animates = true
        pane.contentSize = NSSize(width: 360, height: 258)
        let host = NSHostingController(rootView: GlassMiniPlayer(model: self))
        pane.contentViewController = host
        statusItem = item
        popover = pane
    }

    func hideTray() {
        popover?.close()
        popover = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let panel = popover, let button = statusItem?.button else { return }
        if panel.isShown { panel.performClose(sender) }
        else { panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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

private struct GlassMiniPlayer: View {
    @ObservedObject var model: BitChordGlassBridge
    @State private var seekPosition = 0.0
    @State private var seeking = false

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25)
                .fill(.ultraThinMaterial)
            LinearGradient(colors: [
                Color.white.opacity(0.13),
                Color.black.opacity(0.09),
                Color.black.opacity(0.23)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 25))
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let cover = model.artwork {
                            Image(nsImage: cover).resizable().scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(colors: [.pink.opacity(0.64), .purple.opacity(0.65)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "music.note").font(.system(size: 28, weight: .light))
                            }
                        }
                    }
                    .frame(width: 89, height: 89)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.18)))
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("BITCHORD").font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(2).foregroundStyle(.white.opacity(0.51))
                        Text(model.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(model.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.emit(6) } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 27, height: 27)
                            .background(.white.opacity(0.09), in: Circle())
                    }.buttonStyle(.plain).help("Open BitChord")
                }

                VStack(spacing: 1) {
                    Slider(value: Binding(
                        get: { seeking ? seekPosition : model.elapsed },
                        set: { seekPosition = $0 }
                    ), in: 0...max(1, model.duration), onEditingChanged: { editing in
                        if editing { seekPosition = model.elapsed }
                        seeking = editing
                        if !editing { model.emit(9, seekPosition) }
                    }).tint(.white)
                    HStack {
                        Text(timestamp(seeking ? seekPosition : model.elapsed))
                        Spacer()
                        Text("-" + timestamp(max(0, model.duration - (seeking ? seekPosition : model.elapsed))))
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                }

                HStack(spacing: 32) {
                    Spacer()
                    Button { model.emit(5) } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 20))
                    }.help("Previous")
                    Button { model.emit(3) } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19))
                            .frame(width: 49, height: 49)
                            .foregroundStyle(Color.black.opacity(0.88))
                            .background(.white, in: Circle())
                    }.help(model.isPlaying ? "Pause" : "Play")
                    Button { model.emit(4) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                    }.help("Next")
                    Spacer()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                HStack {
                    Text("Your music, beautifully.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer()
                    Menu {
                        Button("Open BitChord") { model.emit(6) }
                        Button("Settings") { model.emit(7) }
                        Divider()
                        Button("Quit BitChord") { model.emit(8) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 28, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 36)
                    .help("More options")
                }
            }
            .padding(21)
        }
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .frame(width: 360, height: 258)
        .preferredColorScheme(.dark)
    }
}

@_cdecl("bc_start")
public func bc_start(_ callback: CommandCallback?) {
    DispatchQueue.main.async { BitChordGlassBridge.shared.start(callback) }
}

@_cdecl("bc_show_tray")
public func bc_show_tray(_ visible: Int32) {
    DispatchQueue.main.async {
        if visible != 0 { BitChordGlassBridge.shared.showTray() }
        else { BitChordGlassBridge.shared.hideTray() }
    }
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

package com.music.bitchord.desktop

import com.music.bitchord.data.model.artworkAt
import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Native
import java.awt.EventQueue
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Native macOS Now Playing session only. No tray or menu-bar item.
 *
 * Intentionally owns NO playback engine or Google state: it mirrors the already-working
 * DesktopPlaybackEngine and forwards commands to the existing application callbacks.
 */
internal object DesktopMacGlass {
    private fun interface CommandCallback : Callback {
        fun invoke(command: Int, positionSeconds: Double)
    }

    private interface Api : Library {
        fun bc_start(callback: CommandCallback)
        fun bc_update(title: String, artist: String, artwork: String, duration: Double, elapsed: Double, playing: Int)
        fun bc_stop()
    }

    private val api: Api? by lazy {
        if (!DesktopPlatform.isMac) return@lazy null
        runCatching {
            val resource = javaClass.getResourceAsStream("/native/libBitChordGlass.dylib")
                ?: error("native/libBitChordGlass.dylib missing from the desktop app bundle")
            val dylib = Files.createTempFile("bitchord-glass-", ".dylib")
            resource.use { Files.copy(it, dylib, StandardCopyOption.REPLACE_EXISTING) }
            dylib.toFile().deleteOnExit()
            Native.load(dylib.toAbsolutePath().toString(), Api::class.java)
        }.onFailure { DesktopTrackLog.log("macOS Glass bridge load failed: ${it.message}") }.getOrNull()
    }

    private var onPlay: () -> Unit = {}
    private var onPause: () -> Unit = {}
    private var onToggle: () -> Unit = {}
    private var onNext: () -> Unit = {}
    private var onPrevious: () -> Unit = {}
    private var onOpen: () -> Unit = {}
    private var onSettings: () -> Unit = {}
    private var onQuit: () -> Unit = {}
    private var onSeek: (Long) -> Unit = {}

    // Strong reference: JNA callbacks must survive for the whole native session.
    private val callback = CommandCallback { command, seconds ->
        EventQueue.invokeLater {
            when (command) {
                1 -> onPlay()
                2 -> onPause()
                3 -> onToggle()
                4 -> onNext()
                5 -> onPrevious()
                6 -> onOpen()
                7 -> onSettings()
                8 -> onQuit()
                9 -> onSeek((seconds * 1000).toLong().coerceAtLeast(0))
            }
        }
    }

    fun bind(
        play: () -> Unit, pause: () -> Unit, toggle: () -> Unit,
        next: () -> Unit, previous: () -> Unit, open: () -> Unit,
        settings: () -> Unit, quit: () -> Unit, seek: (Long) -> Unit,
    ) {
        onPlay = play
        onPause = pause
        onToggle = toggle
        onNext = next
        onPrevious = previous
        onOpen = open
        onSettings = settings
        onQuit = quit
        onSeek = seek
        runCatching { api?.bc_start(callback) }
            .onFailure { DesktopTrackLog.log("macOS MediaPlayer setup failed: ${it.message}") }
    }

    private var lastTrackId: String? = null
    private var lastPlaying = false
    private var lastDurationMs = -1L
    private var lastPublishNanos = 0L

    fun publish(state: DesktopPlaybackState) {
        // The media center interpolates progress from playbackRate itself. Avoid
        // rebuilding the artwork/metadata dictionary on every audio-position tick.
        val id = state.song?.videoId
        val now = System.nanoTime()
        val unchanged = id == lastTrackId &&
            state.isPlaying == lastPlaying && state.durationMs == lastDurationMs
        if (unchanged && now - lastPublishNanos in 0 until 1_000_000_000L) return
        lastTrackId = id
        lastPlaying = state.isPlaying
        lastDurationMs = state.durationMs
        lastPublishNanos = now
        val song = state.song
        runCatching {
            api?.bc_update(
                song?.title.orEmpty(),
                song?.artist.orEmpty(),
                song?.thumbnailUrl?.artworkAt(480).orEmpty(),
                state.durationMs / 1000.0,
                state.positionMs / 1000.0,
                if (state.isPlaying) 1 else 0,
            )
        }.onFailure { DesktopTrackLog.log("macOS Now Playing update failed: ${it.message}") }
    }

    fun stop() {
        runCatching { api?.bc_stop() }
            .onFailure { DesktopTrackLog.log("macOS media session shutdown failed: ${it.message}") }
    }
}

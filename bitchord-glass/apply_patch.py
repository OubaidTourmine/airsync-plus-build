from pathlib import Path

root = Path("desktopApp/src/main/kotlin/com/music/bitchord/desktop")
def patch(name, changes):
    p = root / name
    content = p.read_text()
    for old, new in changes:
        count = content.count(old)
        if count != 1:
            raise RuntimeError(f"{name}: expected one target; found {count}: {old[:100]!r}")
        content = content.replace(old, new, 1)
    p.write_text(content)
    print("Patched", name)

patch("DesktopStatusNotifier.kt", [
    (
        '''    fun setIcon(svg: ByteArray) {
        if (!isLinuxSession()) {''',
        '''    fun setIcon(svg: ByteArray) {
        if (DesktopPlatform.isMac) return // Native macOS Now Playing has no tray icon.
        if (!isLinuxSession()) {''',
    ),
    (
        '''    fun start() {
        // Windows has no StatusNotifierItem;''',
        '''    fun start() {
        if (DesktopPlatform.isMac) {
            // The user requested no menu-bar status item; the media session remains active.
            return
        }
        // Windows has no StatusNotifierItem;''',
    ),
    (
        '''    fun stop() {
        if (!isLinuxSession()) {''',
        '''    fun stop() {
        if (DesktopPlatform.isMac) {
            // No status item to stop on macOS.
            return
        }
        if (!isLinuxSession()) {''',
    ),
    (
        '''    fun update(title: String?, isPlaying: Boolean) {
        if (!isLinuxSession()) {''',
        '''    fun update(title: String?, isPlaying: Boolean) {
        if (DesktopPlatform.isMac) return // Published exclusively to macOS Control Center.
        if (!isLinuxSession()) {''',
    ),
])

patch("DesktopApp.kt", [
    (
        '''    LaunchedEffect(tray) {
        if (!DesktopPlatform.isMac) DesktopTrayMenu.bind(''',
        '''    LaunchedEffect(tray) {
        if (DesktopPlatform.isMac) DesktopMacGlass.bind(
            play = ::playFromUser,
            pause = ::pauseFromUser,
            toggle = ::togglePlayPauseFromUser,
            next = ::playNext,
            previous = ::playPrevious,
            open = {
                DesktopWindowVisibility.show()
                overlays.nowPlaying = true
            },
            settings = {
                DesktopWindowVisibility.show()
                openSettings()
            },
            quit = {
                playbackEngine.shutdown()
                DesktopMacGlass.stop()
                exitProcess(0)
            },
            seek = { positionMs ->
                if (!DesktopListenTogether.state.value.controlsLocked) {
                    playbackEngine.seekTo(positionMs)
                    partySync.onLocalIntent()
                }
            },
        )
        DesktopTrayMenu.bind(''',
    ),
    (
        '''    LaunchedEffect(tray, trayIconEnabled) {
        if (!trayIconEnabled) return@LaunchedEffect''',
        '''    LaunchedEffect(tray, trayIconEnabled) {
        if (!trayIconEnabled || DesktopPlatform.isMac) return@LaunchedEffect''',
    ),
    (
        '''        tray.update(title = title, isPlaying = playback.isPlaying)
        DesktopTrayMenu.publish(title = title, playing = playback.isPlaying)''',
        '''        if (!DesktopPlatform.isMac) {
            tray.update(title = title, isPlaying = playback.isPlaying)
            DesktopTrayMenu.publish(title = title, playing = playback.isPlaying)
        }''',
    ),
    (
        '''    LaunchedEffect(selectedSong, playback.isPlaying) {
        val title = selectedSong?.let''',
        '''    // Keep the native SwiftUI player and macOS Control Center synchronized.
    // Position is sampled from the original engine; no separate playback engine is created.
    LaunchedEffect(playback.song?.videoId, playback.isPlaying, playback.durationMs, playback.positionMs) {
        if (DesktopPlatform.isMac) DesktopMacGlass.publish(playback)
    }
    DisposableEffect(Unit) {
        onDispose { if (DesktopPlatform.isMac) DesktopMacGlass.stop() }
    }
    LaunchedEffect(selectedSong, playback.isPlaying) {
        val title = selectedSong?.let''',
    ),
])

# Memory optimization: conservative G1 heap sizing, less idle committed heap,
# and a strict decoded-artwork cap. No playback, auth, media-session or audio code touched.
build = Path("desktopApp/build.gradle.kts")
gradle = build.read_text()
old = '''        jvmArgs("-Xmx512m")
        jvmArgs("-XX:+UseG1GC", "-XX:G1PeriodicGCInterval=20000", "-XX:G1PeriodicGCSystemLoadThreshold=0")'''
new = '''        jvmArgs("-Xms48m", "-Xmx384m")
        jvmArgs(
            "-XX:+UseG1GC",
            "-XX:MinHeapFreeRatio=10",
            "-XX:MaxHeapFreeRatio=20",
            "-XX:+UseStringDeduplication",
            "-XX:G1PeriodicGCInterval=10000",
            "-XX:G1PeriodicGCSystemLoadThreshold=0",
        )'''
assert gradle.count(old) == 1, "Expected JVM flag block not found"
build.write_text(gradle.replace(old,new))
print("Tuned JVM memory settings")

artwork = root / "DesktopArtwork.kt"
src = artwork.read_text()
old = '''    internal val budgetBytes: Long =
        (Runtime.getRuntime().maxMemory() / 6).coerceIn(32L * 1024 * 1024, 128L * 1024 * 1024)'''
new = '''    internal val budgetBytes: Long = 32L * 1024 * 1024 // Limit decoded artwork to 32 MiB'''
assert src.count(old) == 1, "Expected artwork cache budget not found"
artwork.write_text(src.replace(old, new))
print("Capped decoded artwork LRU at 32 MiB")

# Releasing the decoded artwork LRU when the main window is hidden keeps only
# the active media session alive, and does not touch playback or authentication.
main = root / "Main.kt"
src = main.read_text()
old = '''    LaunchedEffect(visible) {
        if (visible && state.isMinimized) {
            state.isMinimized = false
        }
    }'''
new = '''    LaunchedEffect(visible) {
        if (visible && state.isMinimized) {
            state.isMinimized = false
        }
        if (!visible) DesktopArtworkCache.clear()
    }'''
assert src.count(old) == 1, "Expected visibility effect not found"
main.write_text(src.replace(old, new))
print("Release artwork cache when player window is hidden")

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
        if (DesktopPlatform.isMac) return // SwiftUI status item uses the app's icon.
        if (!isLinuxSession()) {''',
    ),
    (
        '''    fun start() {
        // Windows has no StatusNotifierItem;''',
        '''    fun start() {
        if (DesktopPlatform.isMac) {
            DesktopMacGlass.showTray(true)
            return
        }
        // Windows has no StatusNotifierItem;''',
    ),
    (
        '''    fun stop() {
        if (!isLinuxSession()) {''',
        '''    fun stop() {
        if (DesktopPlatform.isMac) {
            DesktopMacGlass.showTray(false)
            return
        }
        if (!isLinuxSession()) {''',
    ),
    (
        '''    fun update(title: String?, isPlaying: Boolean) {
        if (!isLinuxSession()) {''',
        '''    fun update(title: String?, isPlaying: Boolean) {
        if (DesktopPlatform.isMac) return // Published by DesktopMacGlass with artwork and position.
        if (!isLinuxSession()) {''',
    ),
])

patch("DesktopApp.kt", [
    (
        '''    LaunchedEffect(tray) {
        DesktopTrayMenu.bind(''',
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

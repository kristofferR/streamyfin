package expo.modules.mpvplayer

/** Physical pause snapshot shared by mpv and Media3, delivered on the UI thread. */
internal data class MpvPauseReport(
    val paused: Boolean,
    val position: Double?,
    val duration: Double,
    val cacheSeconds: Double,
) {
    fun deliver(
        onProgress: (Double, Double, Double) -> Unit,
        onPause: (Boolean) -> Unit,
    ) {
        if (paused && position != null && position.isFinite() && position >= 0) {
            onProgress(position, duration, cacheSeconds)
        }
        // JS immediately persists its last progress tick when this arrives.
        onPause(paused)
    }
}

/** Runs on the existing native worker; all getters are outside policy locks. */
internal fun captureMpvPauseReport(
    expectedPaused: Boolean?,
    isCurrent: () -> Boolean,
    readPaused: () -> Boolean?,
    readPosition: () -> Double?,
    readDuration: () -> Double?,
    readCache: () -> Double?,
): MpvPauseReport? {
    if (!isCurrent()) return null
    val paused = readPaused() ?: return null
    if (!isCurrent() || (expectedPaused != null && paused != expectedPaused)) return null
    val position = if (paused) readPosition() else null
    if (!isCurrent()) return null
    val duration = readDuration() ?: 0.0
    if (!isCurrent()) return null
    val cache = readCache() ?: 0.0
    // Never label a newer running clock with a queued older pause observation.
    if (!isCurrent() || readPaused() != paused || !isCurrent()) return null
    return MpvPauseReport(paused, position, duration, cache)
}

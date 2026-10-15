package expo.modules.mpvplayer

/** Optional native metadata, never a reference to the renderer's mutable caches. */
internal data class MpvFileMetadata(
    val duration: Double?,
    val cache: Double?,
    val width: Int?,
    val height: Int?,
    val rotation: Int?,
) {
    data class Revision(
        val duration: Long = 0,
        val cache: Long = 0,
        val width: Long = 0,
        val height: Long = 0,
        val rotation: Long = 0,
    )

    /** A later property observation wins over an outstanding one-shot read. */
    fun reconcile(current: MpvFileMetadata, before: Revision, after: Revision) = MpvFileMetadata(
        if (before.duration == after.duration) duration ?: current.duration else current.duration,
        if (before.cache == after.cache) cache ?: current.cache else current.cache,
        if (before.width == after.width) width ?: current.width else current.width,
        if (before.height == after.height) height ?: current.height else current.height,
        if (before.rotation == after.rotation) rotation ?: current.rotation else current.rotation,
    )
}

/** Called only on the handle's worker, with ownership checked around each JNI read. */
internal fun captureMpvFileMetadata(
    isCurrent: () -> Boolean,
    readDouble: (String) -> Double?,
    readInt: (String) -> Int?,
): MpvFileMetadata? {
    if (!isCurrent()) return null
    val duration = readDouble("duration")
    if (!isCurrent()) return null
    val cache = readDouble("demuxer-cache-duration")
    if (!isCurrent()) return null
    val width = readInt("video-params/w")
    if (!isCurrent()) return null
    val height = readInt("video-params/h")
    if (!isCurrent()) return null
    val rotation = readInt("video-params/rotate")
    if (!isCurrent()) return null
    return MpvFileMetadata(duration, cache, width, height, rotation)
}

internal data class MpvClockReport(val position: Double?, val duration: Double, val cache: Double)

internal fun captureMpvClockReport(
    isCurrent: () -> Boolean,
    readDouble: (String) -> Double?,
): MpvClockReport? {
    if (!isCurrent()) return null
    val position = readDouble("time-pos")
    if (!isCurrent()) return null
    val duration = readDouble("duration") ?: 0.0
    if (!isCurrent()) return null
    val cache = readDouble("demuxer-cache-duration") ?: 0.0
    if (!isCurrent()) return null
    return MpvClockReport(position?.takeIf { it.isFinite() && it >= 0 }, duration, cache)
}

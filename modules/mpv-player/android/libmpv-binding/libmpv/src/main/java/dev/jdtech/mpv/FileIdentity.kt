package dev.jdtech.mpv

/** An opaque identity for one native player; playlist IDs can repeat in another player. */
class PlaybackSource internal constructor()

data class FileIdentity internal constructor(
    val source: PlaybackSource,
    val playlistEntryId: Long,
)

/** A successful command can still lack an identity if its result was unavailable. */
data class LoadResult internal constructor(
    val status: Int,
    val file: FileIdentity?,
)

package expo.modules.mpvplayer.nativeplayer

/** Both immediate session setup and engine preparation precede JS onLoad. Main-owned. */
internal class LoadAcknowledgement(
    private val isPlaying: () -> Boolean,
    private val acknowledge: (Boolean) -> Unit,
) {
    private var configured = false
    private var prepared = false
    private var sent = false

    fun configured() {
        configured = true
        deliver()
    }

    fun filePrepared() {
        prepared = true
        deliver()
    }

    private fun deliver() {
        if (!configured || !prepared || sent) return
        sent = true
        acknowledge(isPlaying())
    }
}

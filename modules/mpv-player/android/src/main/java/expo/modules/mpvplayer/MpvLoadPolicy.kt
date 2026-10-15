package expo.modules.mpvplayer

/** A copied key; the source token is owned by one native player, never a URL. */
internal data class MpvFileKey(val source: Any, val entry: Long)

/** Serializes command-bound requests and immutable native lifecycle receipts. */
internal class MpvLoadPolicy<H : Any> {
    class Request<H>(val handle: H)
    data class Receipt<H>(val request: Request<H>, val file: MpvFileKey, val event: MpvEventSnapshot, val epoch: Long, val pauseRevision: Long)
    data class PauseCapture<H>(val receipt: Receipt<H>, val revision: Long)
    data class Binding<H>(val accepted: Boolean, val receipts: List<Receipt<H>>)
    enum class Stage { PENDING, PREPARED, TERMINAL }
    private data class Early(val file: MpvFileKey, val event: MpvEventSnapshot)

    companion object {
        // Resource limits, not assumptions about request/start correspondence.
        private const val MAX_EARLY_RECEIPTS = 64
    }

    private var request: Request<H>? = null
    private var root: MpvFileKey? = null
    private var file: MpvFileKey? = null
    private var epoch = 0L
    private var stage = Stage.PENDING
    private var terminal: Receipt<H>? = null
    private var terminalDelivered = false
    private var latestEof: Receipt<H>? = null
    private var eofDelivered = false
    private var pauseRevision = 0L
    private var bindingPending = false
    private var overflowed = false
    private var invalidated = false
    private var loadCompletion: (() -> Unit)? = null
    private val early = mutableListOf<Early>()

    @Synchronized fun begin(handle: H, onLoaded: () -> Unit = {}): Request<H> {
        clear()
        loadCompletion = onLoaded
        return Request(handle).also { request = it; bindingPending = true }
    }

    /** Values are copied before this call. No JNI or callbacks run under this lock. */
    @Synchronized fun receive(handle: H, file: MpvFileKey?, event: MpvEventSnapshot, retainEarly: Boolean): Receipt<H>? {
        val current = request ?: return null
        if (invalidated || current.handle !== handle || file == null) return null
        if (bindingPending) {
            if (retainEarly && !overflowed) {
                if (early.size == MAX_EARLY_RECEIPTS) {
                    overflowed = true
                    early.clear()
                } else {
                    early.add(Early(file, event))
                }
            }
            return null
        }
        return accept(current, file, event)
    }

    @Synchronized fun bind(request: Request<H>, file: MpvFileKey?): Binding<H> {
        if (this.request !== request || invalidated || !bindingPending) return Binding(false, emptyList())
        bindingPending = false
        root = if (overflowed || file?.entry?.let { it < 0 } == true) null else file
        this.file = root
        invalidated = root == null
        if (invalidated) loadCompletion = null
        // Replay actual event order after learning this command's exact root.
        // An early terminal outcome must survive command-result binding.
        val retained = early.mapNotNull { accept(request, it.file, it.event) }
        early.clear()
        return Binding(!invalidated, retained.filter(::isCurrent))
    }

    private fun accept(request: Request<H>, file: MpvFileKey, event: MpvEventSnapshot): Receipt<H>? {
        val root = this.root ?: return null
        if (invalidated) return null
        if (terminal != null) {
            // An ordinary END may await preparation. A later explicit failure
            // or cancellation still cancels it; no further START can revive it.
            if (stage != Stage.TERMINAL && event is MpvEventSnapshot.Event && event.id == MPVLib.MPV_EVENT_START_FILE) {
                this.file = null
                loadCompletion = null
                return null
            }
            if (stage != Stage.TERMINAL && event is MpvEventSnapshot.EndFile &&
                event.reason != MPVLib.MPV_END_FILE_REASON_EOF && this.file == file) {
                val receipt = Receipt(request, file, event, epoch, pauseRevision)
                return terminate(if (event.reason == MPVLib.MPV_END_FILE_REASON_REDIRECT)
                    receipt.copy(event = MpvEventSnapshot.Failure("Playlist inputs are not supported by this player")) else receipt)
            }
            return null
        }
        if (event is MpvEventSnapshot.Event && event.id == MPVLib.MPV_EVENT_START_FILE) {
            if (stage == Stage.TERMINAL) return null
            if (file != root) {
                // An unrelated start cannot borrow this request or keep its old file active.
                this.file = null
                return null
            }
            this.file = file
            epoch++
            stage = Stage.PENDING
            terminal = null
            latestEof = null
            eofDelivered = false
        }
        if (stage == Stage.TERMINAL || this.file != file) return null
        if (event is MpvEventSnapshot.Flag && event.property == "pause") pauseRevision++
        val receipt = Receipt(request, file, event, epoch, pauseRevision)
        if (event is MpvEventSnapshot.Flag && event.property == "eof-reached") {
            latestEof = receipt
            // Baseline replay semantics: a native false rearms completion.
            // SEEK/RESTART alone do not acknowledge any host seek request.
            if (!event.value) eofDelivered = false
        }
        if (event is MpvEventSnapshot.EndFile) {
            if (event.reason == MPVLib.MPV_END_FILE_REASON_REDIRECT) {
                return terminate(receipt.copy(event = MpvEventSnapshot.Failure("Playlist inputs are not supported by this player")))
            }
            if (event.reason == MPVLib.MPV_END_FILE_REASON_EOF) {
                // Keep an already accepted FILE_LOADED and its async track
                // preparation alive until onLoad has run, then deliver EOF.
                terminal = receipt
                latestEof = null
                return receipt
            }
            return terminate(receipt)
        }
        return receipt
    }

    private fun terminate(receipt: Receipt<H>): Receipt<H> {
        stage = Stage.TERMINAL
        loadCompletion = null
        latestEof = null
        terminal = receipt
        terminalDelivered = false
        return receipt
    }

    @Synchronized fun isCurrent(request: Request<H>): Boolean =
        this.request === request && !invalidated && stage != Stage.TERMINAL

    /** Only FILE_LOADED's completed track preparation can acknowledge success. */
    @Synchronized fun takeLoadCompletion(receipt: Receipt<H>): (() -> Unit)? {
        if (!isCurrent(receipt) || stage != Stage.PENDING ||
            receipt.event !is MpvEventSnapshot.Event || receipt.event.id != MPVLib.MPV_EVENT_FILE_LOADED) return null
        stage = Stage.PREPARED
        val completion = loadCompletion
        loadCompletion = null
        return completion?.let { { if (isCurrent(receipt)) it() } }
    }

    @Synchronized fun takeTerminal(receipt: Receipt<H>): Boolean {
        if (!isCurrent(receipt) || terminal !== receipt || terminalDelivered) return false
        if (receipt.event is MpvEventSnapshot.EndFile && receipt.event.reason == MPVLib.MPV_END_FILE_REASON_EOF &&
            stage != Stage.PREPARED) return false
        stage = Stage.TERMINAL
        terminalDelivered = true
        return true
    }

    /** Checked on the serial load worker immediately before stopping rejected input. */
    @Synchronized fun ownsTerminal(receipt: Receipt<H>): Boolean =
        request === receipt.request && !invalidated && terminal === receipt

    /** A failed request can report its error until replaced or stopped. */
    @Synchronized fun owns(request: Request<H>): Boolean = this.request === request

    /** Early EOF waits for FILE_LOADED preparation and onLoad delivery. */
    @Synchronized fun pendingEof(): Receipt<H>? {
        if (stage != Stage.PREPARED) return null
        terminal?.takeIf { !terminalDelivered && it.event is MpvEventSnapshot.EndFile &&
            it.event.reason == MPVLib.MPV_END_FILE_REASON_EOF }?.let { return it }
        return latestEof?.takeIf { it.event is MpvEventSnapshot.Flag && it.event.value && !eofDelivered }
    }

    @Synchronized fun takePlaybackEnd(receipt: Receipt<H>): Boolean {
        if (!isCurrent(receipt) || eofDelivered) return false
        val event = receipt.event
        val heldEof = stage == Stage.PREPARED && latestEof === receipt &&
            event is MpvEventSnapshot.Flag && event.property == "eof-reached" && event.value
        val endedEof = stage == Stage.TERMINAL && terminalDelivered && terminal === receipt && event is MpvEventSnapshot.EndFile &&
            event.reason == MPVLib.MPV_END_FILE_REASON_EOF
        if (!heldEof && !endedEof) return false
        eofDelivered = true
        return true
    }

    @Synchronized fun isCurrent(receipt: Receipt<H>): Boolean =
        request === receipt.request && !invalidated && file == receipt.file && epoch == receipt.epoch &&
            (receipt.event !is MpvEventSnapshot.Flag || receipt.event.property != "eof-reached" || latestEof === receipt) &&
            (receipt.event !is MpvEventSnapshot.Flag || receipt.event.property != "pause" || receipt.pauseRevision == pauseRevision) &&
            (stage != Stage.TERMINAL || terminal === receipt)

    /** A later native pause observation revokes an outstanding clock read. */
    @Synchronized fun capturePause(receipt: Receipt<H>): PauseCapture<H>? =
        if (isCurrent(receipt)) PauseCapture(receipt, pauseRevision) else null

    @Synchronized fun isCurrent(capture: PauseCapture<H>): Boolean =
        isCurrent(capture.receipt) && capture.revision == pauseRevision

    @Synchronized fun invalidate(handle: H): Request<H>? {
        val current = request?.takeIf { it.handle === handle && !invalidated } ?: return null
        invalidated = true
        file = null
        bindingPending = false
        loadCompletion = null
        latestEof = null
        early.clear()
        return current
    }

    @Synchronized fun clear() {
        request = null
        root = null
        file = null
        stage = Stage.PENDING
        terminal = null
        terminalDelivered = false
        latestEof = null
        eofDelivered = false
        bindingPending = false
        overflowed = false
        invalidated = false
        loadCompletion = null
        early.clear()
    }
}

/** Values copied on mpv's event thread, independent of mutable renderer caches. */
internal sealed class MpvEventSnapshot {
    data class Integer(val property: String, val value: Long) : MpvEventSnapshot()
    data class Flag(val property: String, val value: Boolean) : MpvEventSnapshot()
    data class Decimal(val property: String, val value: Double) : MpvEventSnapshot()
    data class Event(val id: Int, val seekGeneration: Long, val seekRequestId: Long?) : MpvEventSnapshot()
    data class EndFile(val reason: Int, val error: Int, val insertId: Long, val insertCount: Int) : MpvEventSnapshot()
    data class Failure(val message: String) : MpvEventSnapshot()

    fun reportTerminal(onEof: () -> Unit, onError: (String) -> Unit) {
        when (this) {
            is EndFile -> when (reason) {
                MPVLib.MPV_END_FILE_REASON_EOF -> onEof()
                MPVLib.MPV_END_FILE_REASON_STOP, MPVLib.MPV_END_FILE_REASON_QUIT,
                MPVLib.MPV_END_FILE_REASON_REDIRECT -> Unit
                else -> onError("mpv playback failed (error $error)")
            }
            is Failure -> onError(message)
            else -> Unit
        }
    }
}

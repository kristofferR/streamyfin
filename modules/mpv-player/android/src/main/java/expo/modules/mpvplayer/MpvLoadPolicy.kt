package expo.modules.mpvplayer

/** A copied key; the source token is owned by one native player, never a URL. */
internal data class MpvFileKey(val source: Any, val entry: Long)

/** Serializes command-bound requests and immutable native lifecycle receipts. */
internal class MpvLoadPolicy<H : Any> {
    class Request<H>(val handle: H)
    data class Receipt<H>(val request: Request<H>, val file: MpvFileKey, val event: MpvEventSnapshot, val epoch: Long)
    data class Binding<H>(val accepted: Boolean, val receipts: List<Receipt<H>>)
    enum class Stage { PENDING, PREPARED, TERMINAL }
    private data class Early(val file: MpvFileKey, val event: MpvEventSnapshot)
    private data class Range(val source: Any, val first: Long, val last: Long) {
        fun contains(file: MpvFileKey) = file.source === source && file.entry in first..last
    }

    companion object {
        // Resource limits, not assumptions about request/start correspondence.
        private const val MAX_EARLY_RECEIPTS = 64
        private const val MAX_REDIRECTS = 64
    }

    private var request: Request<H>? = null
    private var root: MpvFileKey? = null
    private var file: MpvFileKey? = null
    private var epoch = 0L
    private var stage = Stage.PENDING
    private var terminal: Receipt<H>? = null
    private var terminalDelivered = false
    private var mayContinueAfterEof = false
    private var bindingPending = false
    private var overflowed = false
    private var invalidated = false
    private var loadCompletion: (() -> Unit)? = null
    private val early = mutableListOf<Early>()
    private val redirects = mutableListOf<Range>()
    private val retired = mutableSetOf<MpvFileKey>()

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
        // Redirects may precede the result and lead to a non-first child START.
        val retained = early.mapNotNull { accept(request, it.file, it.event) }
        early.clear()
        return Binding(!invalidated, retained.filter(::isCurrent))
    }

    private fun accept(request: Request<H>, file: MpvFileKey, event: MpvEventSnapshot): Receipt<H>? {
        val root = this.root ?: return null
        if (invalidated) return null
        if (event is MpvEventSnapshot.Event && event.id == MPVLib.MPV_EVENT_START_FILE) {
            if (stage == Stage.TERMINAL && !mayContinueAfterEof) return null
            if (file in retired || (file != root && redirects.none { it.contains(file) })) {
                // An unrelated start cannot borrow this request or keep its old file active.
                this.file = null
                return null
            }
            this.file = file
            epoch++
            stage = Stage.PENDING
            terminal = null
            mayContinueAfterEof = false
        }
        if (stage == Stage.TERMINAL || this.file != file) return null
        val receipt = Receipt(request, file, event, epoch)
        if (event is MpvEventSnapshot.EndFile) {
            if (event.reason == MPVLib.MPV_END_FILE_REASON_REDIRECT) {
                val first = event.insertId
                val count = event.insertCount
                val lastAllocated = redirects.maxOfOrNull { it.last } ?: root.entry
                // Pinned playlist_transfer_entries_to assigns ++id_alloc in one loop.
                // See consumer/END_FILE-evidence.md; selection still requires actual START.
                if (first <= maxOf(file.entry, lastAllocated) || count <= 0 || first > Long.MAX_VALUE - (count.toLong() - 1) || redirects.size == MAX_REDIRECTS) {
                    return terminate(receipt.copy(event = MpvEventSnapshot.Failure("Invalid or exhausted mpv playlist lineage")))
                }
                redirects.add(Range(file.source, first, first + (count.toLong() - 1)))
                retired.add(file)
                this.file = null
                stage = Stage.PENDING
                return null
            }
            mayContinueAfterEof = event.reason == MPVLib.MPV_END_FILE_REASON_EOF
            return terminate(receipt)
        }
        return receipt
    }

    private fun terminate(receipt: Receipt<H>): Receipt<H> {
        stage = Stage.TERMINAL
        if (!mayContinueAfterEof) loadCompletion = null
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
        return loadCompletion.also { loadCompletion = null }
    }

    @Synchronized fun takeTerminal(receipt: Receipt<H>): Boolean {
        if (!isCurrent(receipt) || terminal !== receipt || terminalDelivered) return false
        terminalDelivered = true
        return true
    }

    /** A failed request can report its error until replaced or stopped. */
    @Synchronized fun owns(request: Request<H>): Boolean = this.request === request

    @Synchronized fun isCurrent(receipt: Receipt<H>): Boolean =
        request === receipt.request && !invalidated && file == receipt.file && epoch == receipt.epoch &&
            (stage != Stage.TERMINAL || terminal === receipt ||
                (mayContinueAfterEof && !terminalDelivered &&
                    (receipt.event is MpvEventSnapshot.Decimal || receipt.event is MpvEventSnapshot.Flag)))

    @Synchronized fun invalidate(handle: H): Request<H>? {
        val current = request?.takeIf { it.handle === handle && !invalidated } ?: return null
        invalidated = true
        file = null
        bindingPending = false
        loadCompletion = null
        early.clear()
        redirects.clear()
        retired.clear()
        return current
    }

    @Synchronized fun clear() {
        request = null
        root = null
        file = null
        stage = Stage.PENDING
        terminal = null
        terminalDelivered = false
        mayContinueAfterEof = false
        bindingPending = false
        overflowed = false
        invalidated = false
        loadCompletion = null
        early.clear()
        redirects.clear()
        retired.clear()
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

package expo.modules.mpvplayer

/** Correlates receipts with command results, never with request/start ordering. */
internal class MpvLoadPolicy<H : Any, F : Any, E : Any> {
    class Request<H>(val handle: H)
    data class Receipt<H, F, E>(val request: Request<H>, val file: F, val event: E)
    data class Binding<H, F, E>(val accepted: Boolean, val receipts: List<Receipt<H, F, E>>)

    companion object {
        // A resource limit, not an assumption about how many files can start.
        // Overflow rejects the load explicitly instead of silently losing readiness.
        private const val MAX_EARLY_RECEIPTS = 64
    }

    private var request: Request<H>? = null
    private var file: F? = null
    private var bindingPending = false
    private var overflowed = false
    private var invalidated = false
    private val early = mutableListOf<Receipt<H, F, E>>()

    @Synchronized fun begin(handle: H): Request<H> {
        clear()
        return Request(handle).also { request = it; bindingPending = true }
    }

    /** Called at receipt on the native event thread; values in E must be immutable. */
    @Synchronized fun receive(handle: H, file: F?, event: E, retainEarly: Boolean): Receipt<H, F, E>? {
        val current = request ?: return null
        if (invalidated || current.handle !== handle || file == null) return null
        val receipt = Receipt(current, file, event)
        if (bindingPending) {
            if (retainEarly && !overflowed) {
                if (early.size == MAX_EARLY_RECEIPTS) {
                    overflowed = true
                    early.clear()
                } else {
                    early.add(receipt)
                }
            }
            return null
        }
        return receipt.takeIf { this.file == file }
    }

    @Synchronized fun bind(request: Request<H>, file: F?): Binding<H, F, E> {
        if (this.request !== request || invalidated || !bindingPending) return Binding(false, emptyList())
        bindingPending = false
        this.file = if (overflowed) null else file
        invalidated = this.file == null
        val retained = early.filter { it.file == this.file }
        early.clear()
        return Binding(this.file != null, retained)
    }

    @Synchronized fun isCurrent(request: Request<H>): Boolean = this.request === request && !invalidated

    /** A failed request may still report its error, until replaced or stopped. */
    @Synchronized fun owns(request: Request<H>): Boolean = this.request === request

    @Synchronized fun isCurrent(receipt: Receipt<H, F, E>): Boolean =
        request === receipt.request && file == receipt.file

    @Synchronized fun invalidate(handle: H): Request<H>? {
        val current = request?.takeIf { it.handle === handle && !invalidated } ?: return null
        invalidated = true
        file = null
        bindingPending = false
        early.clear()
        return current
    }

    @Synchronized fun clear() {
        request = null
        file = null
        bindingPending = false
        overflowed = false
        invalidated = false
        early.clear()
    }
}

/** Values are copied before leaving mpv's event thread; no renderer caches are read. */
internal sealed class MpvEventSnapshot {
    data class Integer(val property: String, val value: Long) : MpvEventSnapshot()
    data class Flag(val property: String, val value: Boolean) : MpvEventSnapshot()
    data class Decimal(val property: String, val value: Double) : MpvEventSnapshot()
    data class Event(val id: Int, val seekGeneration: Long, val seekRequestId: Long?) : MpvEventSnapshot()
}

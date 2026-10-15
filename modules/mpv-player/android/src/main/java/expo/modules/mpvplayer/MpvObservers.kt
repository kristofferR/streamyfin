package expo.modules.mpvplayer

import java.util.concurrent.CopyOnWriteArrayList

/**
 * The observers of one mpv handle.
 *
 * Callbacks run on mpv's event thread. Holding a lock across an earlier
 * FILE_LOADED callback's subtitle fetch made observer removal wait on network
 * work and froze the UI. The renderer now schedules native load work separately;
 * dispatch still must not hold a lock while calling an observer.
 *
 * Callbacks therefore run over a snapshot with no lock held. The price is
 * that an observer removed while an event is being delivered can still
 * receive that one event.
 */
internal class MpvObservers<T : Any> {
    private val observers = CopyOnWriteArrayList<T>()

    fun add(observer: T) {
        observers.add(observer)
    }

    fun remove(observer: T) {
        observers.remove(observer)
    }

    fun dispatch(block: (T) -> Unit) {
        // Iterating a CopyOnWriteArrayList walks the array as it was when the
        // iteration began.
        for (observer in observers) block(observer)
    }
}

package expo.modules.mpvplayer

import expo.modules.mpvplayer.nativeplayer.MpvOwnership
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class MpvNativeWorkerTest {
    @Test fun retirementAndTheNextHandleDoNotWaitForAnOutgoingSubtitleFetch() {
        val oldWorker = MpvNativeWorker()
        val nextWorker = MpvNativeWorker()
        val oldHandle = Any()
        val nextHandle = Any()
        val policy = MpvLoadPolicy<Any>()
        val request = policy.begin(oldHandle)
        val blocked = CountDownLatch(1)
        val releaseFetch = CountDownLatch(1)
        val fetchReturned = CountDownLatch(1)
        val nextLoad = CountDownLatch(1)
        val mutations = AtomicInteger()
        val teardowns = AtomicInteger()
        try {
            MpvOwnership.claim(MpvOwnership.Owner.EMBEDDED_VIEW, oldHandle) {}
            oldWorker.execute {
                blocked.countDown()
                // A native call need not respond to Java interruption.
                while (true) {
                    try { releaseFetch.await(); break } catch (_: InterruptedException) {}
                }
                if (policy.isCurrent(request)) mutations.incrementAndGet()
                fetchReturned.countDown()
            }
            assertTrue(blocked.await(5, TimeUnit.SECONDS))
            oldWorker.execute { mutations.incrementAndGet() }
            MpvOwnership.claim(MpvOwnership.Owner.NATIVE_SESSION, nextHandle) {
                nextWorker.execute { nextLoad.countDown() }
            }
            policy.clear()
            oldWorker.retire {
                assertFalse(Thread.holdsLock(oldWorker))
                teardowns.incrementAndGet()
                MpvOwnership.release(oldHandle)
            }
            oldWorker.retire { teardowns.incrementAndGet() }
            oldWorker.execute { mutations.incrementAndGet() }
            assertTrue(nextLoad.await(5, TimeUnit.SECONDS))
            assertEquals(1L, releaseFetch.count) // New handle ran before old fetch returned.
            assertEquals(1, teardowns.get())
            releaseFetch.countDown()
            assertTrue(fetchReturned.await(5, TimeUnit.SECONDS))
            assertEquals(0, mutations.get())
        } finally {
            policy.clear()
            releaseFetch.countDown()
            oldWorker.retire { MpvOwnership.release(oldHandle) }
            nextWorker.retire { MpvOwnership.release(nextHandle) }
            MpvOwnership.cancel(nextHandle)
            MpvOwnership.release(oldHandle)
            MpvOwnership.release(nextHandle)
        }
    }
}

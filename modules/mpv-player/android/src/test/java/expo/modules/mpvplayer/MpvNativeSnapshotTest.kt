package expo.modules.mpvplayer

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class MpvNativeSnapshotTest {
    private val loaded = MpvEventSnapshot.Event(MPVLib.MPV_EVENT_FILE_LOADED, 0, null)

    @Test fun metadataReadsRunOnTheHandleWorkerAndNewerPropertiesWinAtDelivery() {
        val worker = MpvNativeWorker()
        val owner = Thread.currentThread()
        val completed = CountDownLatch(1)
        val report = AtomicReference<MpvFileMetadata?>()
        val failure = AtomicReference<Throwable?>()
        try {
            worker.execute {
                try {
                    report.set(captureMpvFileMetadata({ true }, {
                        assertNotSame(owner, Thread.currentThread())
                        if (it == "duration") 100.0 else 5.0
                    }, {
                        assertNotSame(owner, Thread.currentThread())
                        when (it) { "video-params/w" -> 1920; "video-params/h" -> 1080; else -> 90 }
                    }))
                } catch (error: Throwable) { failure.set(error) } finally { completed.countDown() }
            }
            assertTrue(completed.await(5, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            val snapshot = report.get()!!
            val before = MpvFileMetadata.Revision()
            val current = MpvFileMetadata(120.0, 7.0, 3840, 2160, 0)
            assertEquals(snapshot, snapshot.reconcile(current, before, before))
            assertEquals(current, snapshot.reconcile(current, before, MpvFileMetadata.Revision(1, 1, 1, 1, 1)))
            assertEquals(MpvFileMetadata(120.0, 5.0, 1920, 2160, 90),
                snapshot.reconcile(current, before, before.copy(duration = 1, height = 1)))
        } finally { worker.retire {} }
    }

    @Test fun replacementDuringAnyMetadataReadStopsFurtherReads() {
        (1..5).forEach { replaceAt ->
            val policy = MpvLoadPolicy<Any>()
            val handle = Any()
            val file = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), file)
            val receipt = policy.receive(handle, file, loaded, true)!!
            var reads = 0
            fun read() {
                assertFalse(Thread.holdsLock(policy))
                if (++reads == replaceAt) policy.begin(handle)
            }
            assertNull(captureMpvFileMetadata({ policy.isCurrent(receipt) }, { read(); 100.0 }, { read(); 1920 }))
            assertEquals(replaceAt, reads)
        }
    }

    @Test fun laterObservedSeekRestartOrReplacementRevokesAQueuedRestartClock() {
        listOf(MPVLib.MPV_EVENT_SEEK, MPVLib.MPV_EVENT_PLAYBACK_RESTART, -1).forEach { later ->
            val policy = MpvLoadPolicy<Any>()
            val handle = Any()
            val file = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), file)
            val receipt = policy.receive(handle, file,
                MpvEventSnapshot.Event(MPVLib.MPV_EVENT_PLAYBACK_RESTART, 0, null), true)!!
            val clock = captureMpvClockReport({ policy.isCurrentClock(receipt) }, {
                assertFalse(Thread.holdsLock(policy))
                when (it) { "time-pos" -> 80.0; "duration" -> 100.0; else -> 4.0 }
            })!!
            assertEquals(MpvClockReport(80.0, 100.0, 4.0), clock)
            if (later < 0) policy.begin(handle) else
                policy.receive(handle, file, MpvEventSnapshot.Event(later, 0, null), true)
            assertFalse(policy.isCurrentClock(receipt)) // Final main-hop fence.
            assertNull(captureMpvClockReport({ policy.isCurrentClock(receipt) }, { fail("stale JNI read"); null }))
        }
    }

    @Test fun aSeekObservedDuringAClockReadCannotDeliverItsNewerClockAsTheOldRestart() {
        val policy = MpvLoadPolicy<Any>()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        val receipt = policy.receive(handle, file,
            MpvEventSnapshot.Event(MPVLib.MPV_EVENT_PLAYBACK_RESTART, 0, null), true)!!
        var reads = 0
        assertNull(captureMpvClockReport({ policy.isCurrentClock(receipt) }, {
            reads++
            policy.receive(handle, file, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_SEEK, 0, null), true)
            80.0
        }))
        assertEquals(1, reads)
    }
}

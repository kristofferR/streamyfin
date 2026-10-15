package expo.modules.mpvplayer

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class MpvNativeSnapshotTest {
    private val loaded = MpvEventSnapshot.Event(MPVLib.MPV_EVENT_FILE_LOADED, 0, null)

    @Test fun chapterSnapshotIsCapturedOnTheWorkerAndRetainsItsValuesBeforeFinalDelivery() {
        val worker = MpvNativeWorker()
        val owner = Thread.currentThread()
        val policy = MpvLoadPolicy<Any>()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        val receipt = policy.receive(handle, file, MpvEventSnapshot.Integer("chapter-list/count", 2), true)!!
        val completed = CountDownLatch(1)
        val result = AtomicReference<List<Map<String, Any>>?>()
        val failure = AtomicReference<Throwable?>()
        var nativeTitle = "Opening"
        try {
            worker.execute {
                try {
                    fun checkWorker() {
                        assertNotSame(owner, Thread.currentThread())
                        assertFalse(Thread.holdsLock(policy))
                    }
                    result.set(captureMpvChapters({ policy.isCurrent(receipt) },
                        { checkWorker(); 2 }, { checkWorker(); if (it == 0) nativeTitle else null },
                        { checkWorker(); if (it == 0) 12.0 else null }))
                } catch (error: Throwable) { failure.set(error) } finally { completed.countDown() }
            }
            assertTrue(completed.await(5, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            nativeTitle = "Later mutable native value"
            assertEquals(listOf(mapOf("name" to "Opening", "startSec" to 12.0),
                mapOf("name" to "", "startSec" to 0.0)), result.get())
            policy.begin(handle)
            var delivered = false
            if (policy.isCurrent(receipt)) delivered = true
            assertFalse(delivered)
        } finally { worker.retire {} }
    }

    @Test fun invalidationDuringAnyChapterReadStopsWithoutReadingTheReplacement() {
        (1..5).forEach { invalidateAt ->
            val policy = MpvLoadPolicy<Any>()
            val handle = Any()
            val file = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), file)
            val receipt = policy.receive(handle, file, MpvEventSnapshot.Integer("chapter-list/count", 2), true)!!
            var reads = 0
            fun read() {
                assertFalse(Thread.holdsLock(policy))
                if (++reads == invalidateAt) policy.clear()
            }
            assertNull(captureMpvChapters({ policy.isCurrent(receipt) }, { read(); 2 }, { read(); "Old" }, { read(); 12.0 }))
            assertEquals(invalidateAt, reads)
        }
        assertEquals(emptyList<Map<String, Any>>(), captureMpvChapters({ true }, { 0 },
            { fail("empty chapter title read"); null }, { fail("empty chapter time read"); null }))
    }

    @Test fun queuedRestartClockCannotOverwriteNewerDeliveredNativeProgress() {
        val earlierProperty = MpvClockReport(79.0, 100.0, 3.0)
        val workerRead = MpvClockReport(80.0, 100.0, 4.0)
        val laterProperty = MpvClockReport(81.0, 100.0, 5.0)
        assertSame(workerRead, workerRead.reconcileProgress(earlierProperty, earlierProperty))
        assertEquals(workerRead.copy(position = 81.0), workerRead.reconcileProgress(earlierProperty, laterProperty))
        assertSame(workerRead, workerRead.reconcileProgress(null, null))
        assertSame(workerRead, workerRead.reconcileProgress(earlierProperty, laterProperty.copy(position = Double.NaN)))
    }

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

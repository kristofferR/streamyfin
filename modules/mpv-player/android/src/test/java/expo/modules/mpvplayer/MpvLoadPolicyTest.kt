package expo.modules.mpvplayer

import org.junit.Assert.*
import org.junit.Test

class MpvLoadPolicyTest {
    private data class FileId(val handle: Any, val entry: Long)
    private fun policy() = MpvLoadPolicy<Any, FileId, MpvEventSnapshot>()
    private val loaded = MpvEventSnapshot.Event(8, 0, null)

    @Test fun skippedAndArbitrarilyOrderedStartsBindOnlyTheReturnedEntry() {
        val policy = policy()
        val handle = Any()
        val skipped = policy.begin(handle)
        val wanted = policy.begin(handle)
        // No start for the skipped request. Native entry order is not request FIFO.
        listOf(91L, 5L, 77L).forEach {
            policy.receive(handle, FileId(handle, it), loaded, retainEarly = true)
        }
        assertFalse(policy.bind(skipped, FileId(handle, 91)).accepted)
        val binding = policy.bind(wanted, FileId(handle, 5))
        assertTrue(binding.accepted)
        assertEquals(listOf(5L), binding.receipts.map { it.file.entry })
        assertTrue(policy.isCurrent(binding.receipts.single()))
    }

    @Test fun readinessBeforeCommandCompletionSurvivesAndEarlyProgressCanDrop() {
        val policy = policy()
        val handle = Any()
        val file = FileId(handle, 1L shl 40)
        val request = policy.begin(handle)
        assertNull(policy.receive(handle, file, loaded, retainEarly = true))
        assertNull(policy.receive(handle, file, MpvEventSnapshot.Decimal("time-pos", 0.0), retainEarly = false))
        val binding = policy.bind(request, file)
        assertEquals(listOf(loaded), binding.receipts.map { it.event })
        assertTrue(policy.isCurrent(binding.receipts.single()))
    }

    @Test fun rejectedCommandDoesNotReleaseAnOutgoingReadinessOrProgress() {
        val policy = policy()
        val handle = Any()
        val old = FileId(handle, 1)
        val request = policy.begin(handle)
        policy.receive(handle, old, loaded, retainEarly = true)
        val rejected = policy.bind(request, null)
        assertFalse(rejected.accepted)
        assertTrue(rejected.receipts.isEmpty())
        assertNull(policy.receive(handle, old, loaded, retainEarly = true))
    }

    @Test fun sameUrlReloadCannotDeliverOldReceiptsOrMutateNewResumeCache() {
        val policy = policy()
        val handle = Any()
        val first = FileId(handle, 1)
        policy.bind(policy.begin(handle), first)
        val queued = policy.receive(handle, first, MpvEventSnapshot.Decimal("time-pos", 900.0), false)!!
        // Same URL is deliberately absent from identity: only the new native ID matters.
        val second = FileId(handle, 2)
        policy.bind(policy.begin(handle), second)
        var cache = 120.0
        if (policy.isCurrent(queued)) cache = (queued.event as MpvEventSnapshot.Decimal).value
        assertEquals(120.0, cache, 0.0)
        assertNull(policy.receive(handle, first, loaded, true))
    }

    @Test fun immutableReceiptsDoNotReadALaterMutableCacheAtDelivery() {
        val policy = policy()
        val handle = Any()
        val file = FileId(handle, 1)
        policy.bind(policy.begin(handle), file)
        val queued = listOf(120.0, 121.0).map {
            policy.receive(handle, file, MpvEventSnapshot.Decimal("time-pos", it), false)!!
        }
        var cache = 999.0
        val reports = queued.map {
            assertTrue(policy.isCurrent(it))
            cache = (it.event as MpvEventSnapshot.Decimal).value
            cache
        }
        assertEquals(listOf(120.0, 121.0), reports)
    }

    @Test fun stopAndNewHandleWithReusedEntryIdRejectEveryOldHandleReceipt() {
        val policy = policy()
        val oldHandle = Any()
        val oldFile = FileId(oldHandle, 7)
        val oldRequest = policy.begin(oldHandle)
        policy.bind(oldRequest, oldFile)
        val queued = policy.receive(oldHandle, oldFile, loaded, true)!!
        policy.clear()
        val handle = Any()
        val request = policy.begin(handle)
        assertNull(policy.receive(oldHandle, oldFile, loaded, true))
        assertFalse(policy.bind(oldRequest, oldFile).accepted)
        policy.bind(request, FileId(handle, 7))
        assertFalse(policy.isCurrent(queued))
        assertNull(policy.invalidate(oldHandle))
        assertTrue(policy.isCurrent(request))
    }

    @Test fun shutdownDuringCommandCannotBeUndoneByItsLaterResult() {
        val policy = policy()
        val handle = Any()
        val request = policy.begin(handle)
        policy.receive(handle, FileId(handle, 1), loaded, true)
        policy.invalidate(handle)
        assertFalse(policy.bind(request, FileId(handle, 1)).accepted)
        assertNull(policy.receive(handle, FileId(handle, 1), loaded, true))
    }

    @Test fun boundedEarlyLifecycleOverflowFailsExplicitlyInsteadOfLosingReadiness() {
        val policy = policy()
        val handle = Any()
        val request = policy.begin(handle)
        repeat(1000) { policy.receive(handle, FileId(handle, it.toLong()), loaded, true) }
        val binding = policy.bind(request, FileId(handle, 999))
        assertFalse(binding.accepted)
        assertTrue(binding.receipts.isEmpty())
    }
}

package expo.modules.mpvplayer

import org.junit.Assert.*
import org.junit.Test

class MpvLoadPolicyTest {
    private fun policy() = MpvLoadPolicy<Any>()
    private val loaded = MpvEventSnapshot.Event(8, 0, null)

    @Test fun bindingAndEarlyReadinessCannotAcknowledgeBeforeFilePreparation() {
        val policy = policy()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        val events = mutableListOf<String>()
        val acknowledgement = expo.modules.mpvplayer.nativeplayer.LoadAcknowledgement({ true }) {
            assertFalse(Thread.holdsLock(policy))
            events.add("onLoad/sub-add")
        }
        val request = policy.begin(handle, acknowledgement::filePrepared)
        acknowledgement.configured() // Autoplay/setup never waits for FILE_LOADED.
        policy.receive(handle, file, loaded, true)
        val binding = policy.bind(request, file)
        assertTrue(binding.accepted)
        assertTrue(events.isEmpty()) // mpv_command_ret is not file readiness.
        val receipt = binding.receipts.single()
        events.add("initial subtitles/selection complete")
        policy.takeLoadCompletion(receipt)?.invoke()
        events.add("tracksReady")
        assertNull(policy.takeLoadCompletion(receipt))
        assertEquals(listOf("initial subtitles/selection complete", "onLoad/sub-add", "tracksReady"), events)
    }

    @Test fun replacedRejectedAndStoppedPreparationsCannotAcknowledge() {
        val policy = policy()
        val handle = Any()
        var acknowledgements = 0
        val first = policy.begin(handle) { acknowledgements++ }
        val file = MpvFileKey(handle, 1)
        policy.bind(first, file)
        val queued = policy.receive(handle, file, loaded, true)!!
        // The same URL may be reloaded while preparation is on the worker.
        val replacement = policy.begin(handle) { acknowledgements++ }
        assertNull(policy.takeLoadCompletion(queued))
        assertFalse(policy.bind(replacement, null).accepted)
        assertNull(policy.takeLoadCompletion(queued))
        val next = policy.begin(handle) { acknowledgements++ }
        policy.bind(next, MpvFileKey(handle, 2))
        val stopped = policy.receive(handle, MpvFileKey(handle, 2), loaded, true)!!
        policy.clear()
        assertNull(policy.takeLoadCompletion(stopped))
        val newHandle = Any()
        policy.bind(policy.begin(newHandle) { acknowledgements++ }, MpvFileKey(newHandle, 2))
        assertNull(policy.takeLoadCompletion(stopped))
        val current = policy.receive(newHandle, MpvFileKey(newHandle, 2), loaded, true)!!
        policy.takeLoadCompletion(current)?.invoke()
        assertEquals(1, acknowledgements)
    }

    @Test fun skippedAndArbitrarilyOrderedStartsBindOnlyTheReturnedEntry() {
        val policy = policy()
        val handle = Any()
        val skipped = policy.begin(handle)
        val wanted = policy.begin(handle)
        // No start for the skipped request. Native entry order is not request FIFO.
        listOf(91L, 5L, 77L).forEach {
            policy.receive(handle, MpvFileKey(handle, it), loaded, retainEarly = true)
        }
        assertFalse(policy.bind(skipped, MpvFileKey(handle, 91)).accepted)
        val binding = policy.bind(wanted, MpvFileKey(handle, 5))
        assertTrue(binding.accepted)
        assertEquals(listOf(5L), binding.receipts.map { it.file.entry })
        assertTrue(policy.isCurrent(binding.receipts.single()))
    }

    @Test fun readinessBeforeCommandCompletionSurvivesAndEarlyProgressCanDrop() {
        val policy = policy()
        val handle = Any()
        val file = MpvFileKey(handle, 1L shl 40)
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
        val old = MpvFileKey(handle, 1)
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
        val first = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), first)
        val queued = policy.receive(handle, first, MpvEventSnapshot.Decimal("time-pos", 900.0), false)!!
        // Same URL is deliberately absent from identity: only the new native ID matters.
        val second = MpvFileKey(handle, 2)
        policy.bind(policy.begin(handle), second)
        var cache = 120.0
        if (policy.isCurrent(queued)) cache = (queued.event as MpvEventSnapshot.Decimal).value
        assertEquals(120.0, cache, 0.0)
        assertNull(policy.receive(handle, first, loaded, true))
    }

    @Test fun immutableReceiptsDoNotReadALaterMutableCacheAtDelivery() {
        val policy = policy()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
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
        val oldFile = MpvFileKey(oldHandle, 7)
        val oldRequest = policy.begin(oldHandle)
        policy.bind(oldRequest, oldFile)
        val queued = policy.receive(oldHandle, oldFile, loaded, true)!!
        policy.clear()
        val handle = Any()
        val request = policy.begin(handle)
        assertNull(policy.receive(oldHandle, oldFile, loaded, true))
        assertFalse(policy.bind(oldRequest, oldFile).accepted)
        policy.bind(request, MpvFileKey(handle, 7))
        assertFalse(policy.isCurrent(queued))
        assertNull(policy.invalidate(oldHandle))
        assertTrue(policy.isCurrent(request))
    }

    @Test fun shutdownDuringCommandCannotBeUndoneByItsLaterResult() {
        val policy = policy()
        val handle = Any()
        val request = policy.begin(handle)
        policy.receive(handle, MpvFileKey(handle, 1), loaded, true)
        policy.invalidate(handle)
        assertFalse(policy.isCurrent(request))
        assertFalse(policy.bind(request, MpvFileKey(handle, 1)).accepted)
        assertNull(policy.receive(handle, MpvFileKey(handle, 1), loaded, true))
    }

    @Test fun boundedEarlyLifecycleOverflowFailsExplicitlyInsteadOfLosingReadiness() {
        val policy = policy()
        val handle = Any()
        val request = policy.begin(handle)
        repeat(1000) { policy.receive(handle, MpvFileKey(handle, it.toLong()), loaded, true) }
        val binding = policy.bind(request, MpvFileKey(handle, 999))
        assertFalse(binding.accepted)
        assertTrue(binding.receipts.isEmpty())
    }
    private fun start() = MpvEventSnapshot.Event(MPVLib.MPV_EVENT_START_FILE, 0, null)
    private fun end(reason: Int, first: Long = 0, count: Int = 0) =
        MpvEventSnapshot.EndFile(reason, -13, first, count)

    @Test fun actualTerminalReporterKeepsEofStopQuitRedirectAndErrorDistinct() {
        val errors = mutableListOf<String>()
        var eof = 0
        for (reason in listOf(0, 2, 3, 4, 5)) {
            end(reason).reportTerminal(onEof = { eof++ }, onError = { errors.add(it) })
        }
        assertEquals(1, eof)
        assertEquals(listOf("mpv playback failed (error -13)"), errors)
    }

    @Test fun normalEofKeepsTheQueuedPhysicalClockBeforeItsTerminalReport() {
        val policy = policy()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        val progress = policy.receive(handle, file, MpvEventSnapshot.Decimal("time-pos", 1799.9), false)!!
        val terminal = policy.receive(handle, file, end(0), true)!!
        assertTrue(policy.isCurrent(progress))
        assertTrue(policy.takeTerminal(terminal))
        assertFalse(policy.isCurrent(progress))
    }

    @Test fun errorBeforeReadinessIsTerminalOnceAndCannotAcknowledgeSuccess() {
        for (early in listOf(false, true)) {
            val policy = policy()
            val handle = Any()
            val file = MpvFileKey(handle, 1)
            var acknowledged = false
            val request = policy.begin(handle) { acknowledged = true }
            if (!early) policy.bind(request, file)
            policy.receive(handle, file, start(), true)
            val failure = policy.receive(handle, file, end(MPVLib.MPV_END_FILE_REASON_ERROR), true)
            val terminal = if (early) policy.bind(request, file).receipts.single() else failure!!
            assertTrue(policy.takeTerminal(terminal))
            assertFalse(policy.takeTerminal(terminal))
            assertNull(policy.takeLoadCompletion(terminal))
            assertNull(policy.receive(handle, file, loaded, true))
            assertNull(policy.receive(handle, file, start(), true))
            assertFalse(acknowledged)
            policy.clear()
            assertFalse(policy.isCurrent(terminal))
        }
    }

    @Test fun ordinaryHeldEofReportsOnceAndNativeFalseRearmsReplay() {
        val policy = policy()
        val handle = Any()
        val root = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), root)
        policy.receive(handle, root, start(), true)
        val ready = policy.receive(handle, root, loaded, true)!!
        policy.takeLoadCompletion(ready)?.invoke()
        fun flag(value: Boolean) = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", value), true)!!
        val first = flag(true)
        assertTrue(policy.takePlaybackEnd(first))
        assertFalse(policy.takePlaybackEnd(first))
        assertFalse(policy.takePlaybackEnd(flag(true)))
        assertTrue("held EOF leaves the prepared file usable for replay", policy.isCurrent(ready))
        flag(false)
        assertFalse(policy.isCurrent(first))
        val replay = flag(true)
        assertTrue(policy.takePlaybackEnd(replay))
        assertFalse(policy.takePlaybackEnd(replay))
        val terminal = policy.receive(handle, root, end(0), true)!!
        assertTrue(policy.takeTerminal(terminal))
        assertFalse("property and END cannot report the same EOF twice", policy.takePlaybackEnd(terminal))
    }

    @Test fun earlyEofCannotOvertakeFilePreparationAndOnLoad() {
        for (beforeResult in listOf(false, true)) {
            val policy = policy()
            val handle = Any()
            val root = MpvFileKey(handle, 1)
            val effects = mutableListOf<String>()
            val request = policy.begin(handle) { effects.add("onLoad") }
            if (!beforeResult) policy.bind(request, root)
            policy.receive(handle, root, start(), true)
            val prepared = policy.receive(handle, root, loaded, true)
            val eof = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", true), true)
            val receipts = if (beforeResult) policy.bind(request, root).receipts else listOf(prepared!!, eof!!)
            val ready = receipts.single { it.event == loaded }
            val ended = receipts.single { it.event is MpvEventSnapshot.Flag }
            assertFalse(policy.takePlaybackEnd(ended))
            assertNull(policy.pendingEof())
            effects.add("subtitles prepared")
            policy.takeLoadCompletion(ready)?.invoke()
            val pending = policy.pendingEof()!!
            if (policy.takePlaybackEnd(pending) && policy.isCurrent(pending)) {
                assertFalse(Thread.holdsLock(policy))
                effects.add("onPlaybackEnded")
            }
            assertEquals(listOf("subtitles prepared", "onLoad", "onPlaybackEnded"), effects)
            assertNull(policy.pendingEof())
        }
    }

    @Test fun staleQueuedEofCannotSurviveFalseReplacementShutdownErrorOrRedirect() {
        for (change in listOf("false", "replace", "shutdown", "error", "redirect")) {
            val policy = policy()
            val handle = Any()
            val root = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), root)
            val ready = policy.receive(handle, root, loaded, true)!!
            policy.takeLoadCompletion(ready)?.invoke()
            val queued = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", true), true)!!
            when (change) {
                "false" -> policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", false), true)
                "replace" -> policy.bind(policy.begin(handle), MpvFileKey(handle, 2))
                "shutdown" -> policy.invalidate(handle)
                "error" -> policy.receive(handle, root, end(4), true)
                "redirect" -> policy.receive(handle, root, end(5, 10, 2), true)
            }
            assertFalse("stale EOF after $change", policy.takePlaybackEnd(queued))
            assertFalse(policy.isCurrent(queued))
        }
    }

    @Test fun finalDeliveryStillRejectsAnErrorAfterEofDeduplicationWasTaken() {
        val policy = policy()
        val handle = Any()
        val root = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), root)
        val ready = policy.receive(handle, root, loaded, true)!!
        policy.takeLoadCompletion(ready)?.invoke()
        val eof = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", true), true)!!
        assertTrue(policy.takePlaybackEnd(eof))
        policy.receive(handle, root, end(4), true)
        assertFalse("the final delegate fence runs after taking the latch", policy.isCurrent(eof))
    }

    @Test fun nativeLoopSeekAndRestartEventsDoNotInventEofOrSeekAcknowledgements() {
        val policy = policy()
        val handle = Any()
        val root = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), root)
        val ready = policy.receive(handle, root, loaded, true)!!
        policy.takeLoadCompletion(ready)?.invoke()
        // Per-file looping remains mpv's loop-file=inf/no operation. Only
        // native EOF true/false values drive the baseline completion latch.
        policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", false), true)
        policy.receive(handle, root, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_SEEK, 0, null), true)
        policy.receive(handle, root, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_PLAYBACK_RESTART, 0, null), true)
        assertNull(policy.pendingEof())
        val eof = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", true), true)!!
        assertTrue(policy.takePlaybackEnd(eof))
        policy.receive(handle, root, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_SEEK, 0, null), true)
        policy.receive(handle, root, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_PLAYBACK_RESTART, 0, null), true)
        assertFalse(policy.takePlaybackEnd(eof))
        policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", false), true)
        val replay = policy.receive(handle, root, MpvEventSnapshot.Flag("eof-reached", true), true)!!
        assertTrue(policy.takePlaybackEnd(replay))
    }

    @Test fun redirectFailsOnceBeforeAnyChildSuccessIncludingBeforeResultBinding() {
        for (early in listOf(false, true)) {
            val policy = policy()
            val handle = Any()
            val root = MpvFileKey(handle, 1)
            val child = MpvFileKey(handle, 10)
            var acknowledged = false
            val request = policy.begin(handle) { acknowledged = true }
            if (!early) policy.bind(request, root)
            policy.receive(handle, root, start(), true)
            policy.receive(handle, root, loaded, true) // Preparation may still be queued.
            val redirected = policy.receive(handle, root, end(5, 10, 3), true)
            policy.receive(handle, child, start(), true)
            policy.receive(handle, child, loaded, true)
            val failure = if (early) policy.bind(request, root).receipts.single() else redirected!!
            assertTrue(policy.takeTerminal(failure))
            assertFalse(policy.takeTerminal(failure))
            val errors = mutableListOf<String>()
            var hostCompletions = 0
            failure.event.reportTerminal(onEof = { hostCompletions++ }, onError = { errors.add(it) })
            assertEquals(listOf("Playlist inputs are not supported by this player"), errors)
            assertFalse(acknowledged)
            assertNull(policy.takeLoadCompletion(failure))
            // Deliver the child's EOF all the way to the host BEFORE the next
            // child's START. There is no earlier START to retire this receipt.
            val childEof = policy.receive(handle, child, end(0), true)
            childEof?.let { if (policy.takeTerminal(it)) it.event.reportTerminal({ hostCompletions++ }, { errors.add(it) }) }
            assertEquals(0, hostCompletions)
            assertNull(policy.receive(handle, MpvFileKey(handle, 11), start(), true))
            assertNull(policy.receive(handle, child, MpvEventSnapshot.Decimal("time-pos", 100.0), false))
            assertEquals(1, errors.size)
        }
    }

    @Test fun rejectionUsesOnlyTheAcceptedEndReason() {
        for ((first, count) in listOf(10L to 3, 0L to 0, Long.MAX_VALUE to 2)) {
            val policy = policy()
            val handle = Any()
            val root = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), root)
            val failure = policy.receive(handle, root, end(5, first, count), true)!!
            assertEquals(MpvEventSnapshot.Failure("Playlist inputs are not supported by this player"), failure.event)
            assertTrue(policy.ownsTerminal(failure))
        }
        // Ordinary readiness without a playlist END remains valid. The policy
        // accepts native identities and has no URL/suffix input to classify.
        val policy = policy()
        val handle = Any()
        val root = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), root)
        assertNotNull(policy.receive(handle, root, loaded, true))
    }

    @Test fun rejectedInputStopCannotCrossReplacementOrHandleReuse() {
        val policy = policy()
        val handle = Any()
        val root = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), root)
        val failure = policy.receive(handle, root, end(5, 10, 2), true)!!
        assertTrue(policy.ownsTerminal(failure))
        policy.bind(policy.begin(handle), MpvFileKey(handle, 20))
        assertFalse(policy.ownsTerminal(failure))
        policy.clear()
        val newHandle = Any()
        policy.bind(policy.begin(newHandle), MpvFileKey(newHandle, 1))
        assertFalse(policy.ownsTerminal(failure))
        assertNull(policy.receive(handle, root, loaded, true))
    }

    @Test fun terminalOutcomesNeverReopenOnUnexpectedStart() {
        for (reason in listOf(0, 2, 3, 4, 5)) {
            val policy = policy()
            val handle = Any()
            val root = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), root)
            val terminal = policy.receive(handle, root, end(reason), true)!!
            assertTrue(policy.takeTerminal(terminal))
            assertNull(policy.receive(handle, root, start(), true))
            assertNull(policy.receive(handle, MpvFileKey(handle, 10), start(), true))
            assertNull(policy.receive(handle, root, loaded, true))
        }
    }
}

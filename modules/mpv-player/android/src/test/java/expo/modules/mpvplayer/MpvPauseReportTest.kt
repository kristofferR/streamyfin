package expo.modules.mpvplayer

import org.junit.Assert.*
import org.junit.Test

class MpvPauseReportTest {
    @Test fun workerCaptureKeepsMatchingMetadataAndNeverRunsGettersUnderPolicyLock() {
        val policy = MpvLoadPolicy<Any>()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        val receipt = policy.receive(handle, file, MpvEventSnapshot.Flag("pause", true), true)!!
        val capture = policy.capturePause(receipt)!!
        var position = 45.88
        var duration = 120.0
        var cache = 6.0
        val worker = java.util.concurrent.Executors.newSingleThreadExecutor()
        val caller = Thread.currentThread()
        try {
            val report = worker.submit<MpvPauseReport?> {
                captureMpvPauseReport(
                    expectedPaused = true,
                    isCurrent = { policy.isCurrent(capture) },
                    readPaused = {
                        assertNotSame(caller, Thread.currentThread())
                        assertFalse(Thread.holdsLock(policy))
                        true
                    },
                    readPosition = { position }, readDuration = { duration }, readCache = { cache },
                )
            }.get(5, java.util.concurrent.TimeUnit.SECONDS)!!
            position = 999.0
            duration = 999.0
            cache = 999.0
            assertEquals(MpvPauseReport(true, 45.88, 120.0, 6.0), report)
            val effects = mutableListOf<String>()
            report.deliver({ p, d, c -> effects.add("$p/$d/$c") }, { effects.add("pause=$it") })
            assertEquals(listOf("45.88/120.0/6.0", "pause=true"), effects)
        } finally {
            worker.shutdownNow()
        }
    }

    @Test fun rapidPauseResumeRevokesQueuedCaptureAndAlreadyCapturedPause() {
        val policy = MpvLoadPolicy<Any>()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        fun observe(paused: Boolean) = policy.capturePause(
            policy.receive(handle, file, MpvEventSnapshot.Flag("pause", paused), true)!!,
        )!!
        fun snapshot(capture: MpvLoadPolicy.PauseCapture<Any>, expected: Boolean, nativePaused: Boolean): MpvPauseReport? =
            captureMpvPauseReport(expected, { policy.isCurrent(capture) }, { nativePaused },
                { 45.88 }, { 120.0 }, { 6.0 })

        val paused = observe(true)
        val queuedPause = snapshot(paused, true, true)!!
        val resumed = observe(false)
        assertFalse(policy.isCurrent(paused)) // Cannot mutate the pause cache at final delivery.
        assertNull(snapshot(paused, true, false))
        assertEquals(false, snapshot(resumed, false, false)!!.paused)
        // A clock read for an old true is forbidden even before the newer
        // native property notification reaches the event thread.
        val secondPause = observe(true)
        assertNull(captureMpvPauseReport(true, { policy.isCurrent(secondPause) }, { false },
            { fail("must not label a running clock as the queued pause"); 999.0 }, { 120.0 }, { 6.0 }))
        assertEquals(45.88, queuedPause.position!!, 0.0)
    }

    @Test fun replacementDuringClockReadAndNewerPauseBeforeFinalDeliveryRevokeSnapshots() {
        for (change in listOf("replacement", "shutdown", "resume", "new handle")) {
            val policy = MpvLoadPolicy<Any>()
            val handle = Any()
            val file = MpvFileKey(handle, 1)
            policy.bind(policy.begin(handle), file)
            val capture = policy.capturePause(policy.receive(handle, file, MpvEventSnapshot.Flag("pause", true), true)!!)!!
            fun invalidate() {
                when (change) {
                    "replacement" -> policy.begin(handle)
                    "shutdown" -> policy.invalidate(handle)
                    "resume" -> policy.receive(handle, file, MpvEventSnapshot.Flag("pause", false), true)
                    "new handle" -> policy.begin(Any())
                }
            }
            val report = captureMpvPauseReport(true, { policy.isCurrent(capture) }, { true },
                { invalidate(); 999.0 }, { 120.0 }, { 6.0 })
            assertNull("$change during native read", report)
            assertFalse(policy.isCurrent(capture))
        }
    }

    @Test fun fileLoadedReconciliationCannotOverwriteANewerPauseObservation() {
        val policy = MpvLoadPolicy<Any>()
        val handle = Any()
        val file = MpvFileKey(handle, 1)
        policy.bind(policy.begin(handle), file)
        val ready = policy.receive(handle, file, MpvEventSnapshot.Event(MPVLib.MPV_EVENT_FILE_LOADED, 0, null), true)!!
        val capture = policy.capturePause(ready)!!
        val report = captureMpvPauseReport(null, { policy.isCurrent(capture) }, { false },
            { fail("resume does not read the stopped clock"); null }, { 120.0 }, { 6.0 })!!
        assertFalse(report.paused)
        policy.receive(handle, file, MpvEventSnapshot.Flag("pause", true), true)
        assertFalse(policy.isCurrent(capture))
        assertTrue("track preparation retains its independent lifetime", policy.isCurrent(ready))
    }

    @Test fun pauseChangingDuringReadCannotPublishItsNewerClock() {
        var paused = true
        assertNull(captureMpvPauseReport(true, { true }, { paused },
            { paused = false; 999.0 }, { 120.0 }, { 6.0 }))
    }

    @Test fun pausePersistsPhysicalPositionBeforePlaybackState() {
        var lastReportedPosition = 44.833
        var persistedPausePosition: Double? = null
        val events = mutableListOf<String>()
        MpvPauseReport(true, 45.88, 120.0, 6.0).deliver(
            onProgress = { position, _, _ ->
                lastReportedPosition = position
                events += "progress"
            },
            onPause = { paused ->
                assertTrue(paused)
                persistedPausePosition = lastReportedPosition
                events += "pause"
            },
        )
        assertEquals(45.88, persistedPausePosition!!, 0.000001)
        assertEquals(listOf("progress", "pause"), events)
    }

    @Test fun queuedPauseRetainsItsPhysicalSnapshotAcrossLaterSeeks() {
        var enginePosition = 56.708
        val queuedReport = MpvPauseReport(true, enginePosition, 120.0, 3.0)
        enginePosition = 120.0
        var reportedPosition = -1.0
        queuedReport.deliver(
            onProgress = { position, _, _ -> reportedPosition = position },
            onPause = {},
        )
        assertEquals(120.0, enginePosition, 0.0)
        assertEquals(56.708, reportedPosition, 0.000001)
    }

    @Test fun progressReentryCannotTurnAPausedReportIntoPlaying() {
        var enginePaused = true
        var lastReportedPosition = 20.0
        val persisted = mutableListOf<Pair<Double, Boolean>>()
        val pausedSnapshot = MpvPauseReport(enginePaused, 20.8, 120.0, 3.0)
        pausedSnapshot.deliver(
            onProgress = { position, _, _ ->
                lastReportedPosition = position
                // A progress consumer can initiate a newer playback action.
                enginePaused = false
            },
            onPause = { paused -> persisted += lastReportedPosition to paused },
        )
        assertFalse(enginePaused)
        assertEquals(listOf(20.8 to true), persisted)
    }

    @Test fun missingPhysicalClockDoesNotReportAnOptimisticSeekTarget() {
        for (position in listOf(null, Double.NaN, Double.POSITIVE_INFINITY, -1.0)) {
            var progressReported = false
            var pauseReported = false
            MpvPauseReport(true, position, 120.0, 0.0).deliver(
                onProgress = { _, _, _ -> progressReported = true },
                onPause = { pauseReported = it },
            )
            assertFalse(progressReported)
            assertTrue(pauseReported)
        }
    }

    @Test fun resumeKeepsPlayingProgressThrottle() {
        var progressReported = false
        var reportedPaused: Boolean? = null
        MpvPauseReport(false, 56.708, 120.0, 0.0).deliver(
            onProgress = { _, _, _ -> progressReported = true },
            onPause = { reportedPaused = it },
        )
        assertFalse(progressReported)
        assertEquals(false, reportedPaused)
    }
}

package expo.modules.mpvplayer.nativeplayer

import org.junit.Assert.assertEquals
import org.junit.Test

class LoadAcknowledgementTest {
    @Test fun asynchronousPreparationDoesNotDelaySetupAndAcknowledgesOnlyOnce() {
        val events = mutableListOf<String>()
        val acknowledgement = LoadAcknowledgement({ true }) { events.add("onLoad") }
        events.add("autoplay/setup")
        acknowledgement.configured()
        assertEquals(listOf("autoplay/setup"), events)
        acknowledgement.filePrepared()
        acknowledgement.filePrepared()
        assertEquals(listOf("autoplay/setup", "onLoad"), events)
    }

    @Test fun synchronousEngineStillAcknowledgesAfterSessionSetup() {
        val events = mutableListOf<String>()
        val acknowledgement = LoadAcknowledgement({ true }) { events.add("onLoad") }
        acknowledgement.filePrepared()
        assertEquals(emptyList<String>(), events)
        events.add("autoplay/setup")
        acknowledgement.configured()
        acknowledgement.configured()
        assertEquals(listOf("autoplay/setup", "onLoad"), events)
    }

    @Test fun delayedAcknowledgementSnapshotsBothPlayStateTransitions() {
        for (initial in listOf(false, true)) {
            var isPlaying = initial
            val states = mutableListOf<Boolean>()
            val acknowledgement = LoadAcknowledgement({ isPlaying }) { states.add(it) }
            acknowledgement.configured()
            // The real transition was emitted while JS still awaited onLoad.
            isPlaying = !initial
            acknowledgement.filePrepared()
            isPlaying = initial
            acknowledgement.filePrepared()
            assertEquals(listOf(!initial), states)
        }
    }
}

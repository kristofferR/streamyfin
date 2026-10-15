package expo.modules.mpvplayer.nativeplayer

import org.junit.Assert.assertEquals
import org.junit.Test

class LoadAcknowledgementTest {
    @Test fun asynchronousPreparationDoesNotDelaySetupAndAcknowledgesOnlyOnce() {
        val events = mutableListOf<String>()
        val acknowledgement = LoadAcknowledgement { events.add("onLoad") }
        events.add("autoplay/setup")
        acknowledgement.configured()
        assertEquals(listOf("autoplay/setup"), events)
        acknowledgement.filePrepared()
        acknowledgement.filePrepared()
        assertEquals(listOf("autoplay/setup", "onLoad"), events)
    }

    @Test fun synchronousEngineStillAcknowledgesAfterSessionSetup() {
        val events = mutableListOf<String>()
        val acknowledgement = LoadAcknowledgement { events.add("onLoad") }
        acknowledgement.filePrepared()
        assertEquals(emptyList<String>(), events)
        events.add("autoplay/setup")
        acknowledgement.configured()
        acknowledgement.configured()
        assertEquals(listOf("autoplay/setup", "onLoad"), events)
    }
}

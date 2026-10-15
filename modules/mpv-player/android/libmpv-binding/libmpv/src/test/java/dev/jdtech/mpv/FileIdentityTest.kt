package dev.jdtech.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class FileIdentityTest {
    @Test fun samePlayerAndEntryMatchAcrossCommandAndEvent() {
        val source = PlaybackSource()
        val command = FileIdentity(source, 1L shl 40)
        val event = FileIdentity(source, 1L shl 40)
        assertEquals(command, event)
    }

    @Test fun stopThenNewPlayerCannotReuseAnOldFileIdentity() {
        assertNotEquals(FileIdentity(PlaybackSource(), 1), FileIdentity(PlaybackSource(), 1))
    }

    @Test fun sameUrlReloadsWithDistinctEntryIdsStayDistinct() {
        val source = PlaybackSource()
        assertNotEquals(FileIdentity(source, 10), FileIdentity(source, 11))
    }
}

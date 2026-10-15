package dev.jdtech.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class FileIdentityTest {
    @Test fun optionalEndObserverKeepsThePreviousIdentifiedEventBehavior() {
        val events = mutableListOf<Int>()
        val observer = object : MPVLib.IdentifiedEventObserver {
            override fun event(eventId: Int, file: FileIdentity?) { events.add(eventId) }
        }
        observer.endFile(FileIdentity(PlaybackSource(), 1), EndFile(4, -13, 0, 0))
        assertEquals(listOf(7), events)
    }
    @Test fun endPayloadRetainsReasonErrorAndFullWidthInsertionIdentity() {
        val end = EndFile(5, -13, 1L shl 40, 3)
        assertEquals(5, end.reason)
        assertEquals(-13, end.error)
        assertEquals(1L shl 40, end.playlistInsertId)
        assertEquals(3, end.playlistInsertCount)
    }
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

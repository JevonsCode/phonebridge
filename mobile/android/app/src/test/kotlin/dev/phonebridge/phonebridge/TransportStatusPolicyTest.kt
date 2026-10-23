package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class TransportStatusPolicyTest {
    @Test fun oldHubAndDisconnectedTransportNeverReceiveStatusFrame() {
        assertNull(TransportStatusPolicy.message(false, true, true, "A", "A", "Work"))
        assertNull(TransportStatusPolicy.message(true, false, true, "A", "A", "Work"))
    }
    @Test fun consentChangesReadOnlyAndHandoffUpdatesAllComputers() {
        val before = TransportStatusPolicy.message(true, true, false, "A", "A", "Work")!!
        assertTrue(before.getBoolean("readOnly"))
        assertTrue(before.getBoolean("controlling"))
        val granted = TransportStatusPolicy.message(true, true, true, "A", "A", "Work")!!
        assertFalse(granted.getBoolean("readOnly"))
        val previous = TransportStatusPolicy.message(true, true, true, "A", "B", "Home")!!
        val selected = TransportStatusPolicy.message(true, true, false, "B", "B", "Home")!!
        assertFalse(previous.getBoolean("controlling"))
        assertEquals("Home", previous.getString("controlOwnerName"))
        assertTrue(selected.getBoolean("controlling"))
        assertTrue(selected.getBoolean("readOnly"))
        assertEquals(setOf("type", "readOnly", "controlling", "controlOwnerName", "waitingCount"), selected.keys().asSequence().toSet())
    }
    @Test fun releaseClearsControlMetadata() {
        val released = TransportStatusPolicy.message(true, true, true, "A", null, null)!!
        assertEquals("status", released.getString("type"))
        assertFalse(released.getBoolean("controlling"))
        assertEquals("", released.getString("controlOwnerName"))
    }
}

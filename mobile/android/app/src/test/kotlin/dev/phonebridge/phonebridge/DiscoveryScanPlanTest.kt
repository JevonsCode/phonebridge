package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class DiscoveryScanPlanTest {
    @Test fun coversTheOtherHalfOfA23InsteadOfShrinkingItTo24() {
        val first = DiscoveryScanPlan.batch("192.168.0.20", 23, 0, "192.168.0.111")
        val next = DiscoveryScanPlan.batch("192.168.0.20", 23, first.nextOffset, null)
        assertTrue((first.targets + next.targets).contains("192.168.1.30"))
        assertFalse((first.targets + next.targets).contains("192.168.2.30"))
        assertFalse(first.targets.contains("192.168.0.20"))
        // A /23 has 510 usable addresses. Two 256-address batches wrap by two,
        // while still covering every peer, excluding this phone and broadcast.
        assertEquals(509, (first.targets + next.targets).distinct().size)
    }
    @Test fun largeSubnetsRotateBoundedBatchesAndTryTheSavedHostFirst() {
        val first = DiscoveryScanPlan.batch("10.2.12.20", 16, 0, "10.2.1.9")
        val second = DiscoveryScanPlan.batch("10.2.12.20", 16, first.nextOffset, "10.2.1.9")
        assertEquals("10.2.1.9", first.targets.first())
        assertTrue(first.targets.size <= 257)
        assertNotEquals(first.targets, second.targets)
        assertTrue(second.targets.any { it.startsWith("10.2.13.") })
    }
    @Test fun pointToPointSubnetIncludesItsOnlyPeer() {
        assertEquals(listOf("192.168.1.11"), DiscoveryScanPlan.batch("192.168.1.10", 31, 0, null).targets)
        assertTrue(DiscoveryScanPlan.batch("192.168.1.10", 32, 0, null).targets.isEmpty())
    }
}

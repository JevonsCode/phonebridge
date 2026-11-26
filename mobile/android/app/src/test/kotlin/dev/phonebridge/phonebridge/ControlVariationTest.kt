package dev.phonebridge.phonebridge

import kotlin.random.Random
import org.junit.Assert.*
import org.junit.Test

class ControlVariationTest {
    @Test fun offsetsCoverTheDiskAndRespectClippedTargets() {
        val random = Random(14)
        val center = 21.5f to 40f
        val offsets = mutableSetOf<Pair<Float, Float>>()
        repeat(6000) {
            val (x, y) = ControlVariation.tap(center, random) { _, _ -> true }
            val dx = x - center.first
            val dy = y - center.second
            assertTrue(dx * dx + dy * dy <= 100f)
            offsets += dx to dy
        }
        assertEquals(317, offsets.size) // Every integer point in the disk, including the center.
        repeat(100) {
            val (x, y) = ControlVariation.tap(center, random) { x, y -> x in 21f..22f && y in 39f..42f }
            assertTrue(x in 21f..22f && y in 39f..42f)
        }
        assertEquals(center, ControlVariation.tap(center, random) { _, _ -> false })
    }

    @Test fun delaysSpanTheRequestedIntervalAndExcludeReadOperations() {
        val random = Random(87)
        val delays = List(15000) { ControlVariation.delayMillis(random) }
        assertTrue(delays.all { it in 300L..1300L })
        assertEquals(300L, delays.minOrNull())
        assertEquals(1300L, delays.maxOrNull())
        assertTrue("tap" in ControlVariation.mutations && "node_action" in ControlVariation.mutations)
        assertTrue(listOf("state", "screenshot", "get_clipboard", "file_offer").none { it in ControlVariation.mutations })
        assertFalse(AutomationPreferenceDefaults.value("tapJitter"))
        assertFalse(AutomationPreferenceDefaults.value("randomControlDelay"))
    }
}

package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.*
import org.junit.Test

class OperationTrailTest {
    @Test fun delayedOverlayStateEventRemainsOwnedAfterRemovalAndSettlement() {
        val windows = OwnedTrailWindows()
        windows.remember(367, 14511460, 14511486)
        windows.retire(14511460, 14511577)
        // Real ROM reproduced a 554 ms delay between event creation and delivery.
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            367, 14511470, 14512024))
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            367, 14511577, 14512024))
    }

    @Test fun foreignReusedWindowIdOutsideItsOwnedLifetimeNeverInheritsOwnership() {
        val windows = OwnedTrailWindows()
        windows.remember(367, 1000, 1001)
        windows.retire(1000, 1100)
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 367, 1101, 1600))
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 367, 999, 1600))
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOWS_CHANGED, 365, 1050, 1600))
        // No app content/text/focus/scroll events are suppressed, even for a matching id.
        for (type in listOf(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED)) {
            assertFalse(windows.ownsEvent(type, 367, 1050, 1600))
        }
        windows.remember(367, 2000, 2001)
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 367, 1700, 2100))
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 367, 2001, 2100))
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 367, 1050, 2100))
    }

    @Test fun ownershipMetadataIsBoundedByTimeAndWindowCount() {
        val windows = OwnedTrailWindows()
        windows.remember(1, 100, 100)
        windows.retire(100, 150)
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1, 110, 5150))
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1, 110, 5151))
        for (id in 1..OwnedTrailWindows.MAX_WINDOWS + 1) {
            windows.remember(id, 6000L + id, 6000L + id)
            windows.retire(6000L + id, 6001L + id)
        }
        assertFalse(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1, 6001, 6200))
        assertTrue(windows.ownsEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            OwnedTrailWindows.MAX_WINDOWS + 1, 6001L + OwnedTrailWindows.MAX_WINDOWS, 6200))
    }

    @Test fun failedCommitThatAlreadyMutatedMemoryRestoresThePriorValue() {
        for (prior in listOf(true, false)) {
            var memory = prior
            val writes = mutableListOf<Boolean>()
            val persistence = TrailPreferencePersistence()
            assertThrows(IllegalStateException::class.java) {
                persistence.save(!prior, { memory }) { value ->
                    memory = value // Android updates memory before reporting failed disk persistence.
                    writes.add(value)
                    writes.size > 1
                }
            }
            assertEquals(listOf(!prior, prior), writes)
            assertEquals(prior, memory)
            assertEquals(prior, persistence.read { memory })
        }
    }

    @Test fun failedRollbackKeepsEffectiveValueAndSuccessfulRetryClearsTheFallback() {
        var memory = true
        var attempts = 0
        val persistence = TrailPreferencePersistence()
        assertThrows(IllegalStateException::class.java) {
            persistence.save(false, { memory }) { value ->
                attempts++
                if (attempts == 1) { memory = value; false }
                else throw IllegalStateException("Rollback disk failure")
            }
        }
        assertFalse(memory)
        assertTrue(persistence.read { memory })
        persistence.save(false, { memory }) { value -> memory = value; true }
        assertFalse(persistence.read { memory })
        // A new process also sees the successfully persisted choice.
        assertFalse(TrailPreferencePersistence().read { memory })
    }

    @Test fun swipeRevealsOnlyTheDistanceAlreadyTravelledInPhysicalPixels() {
        val motion = TrailMotion("swipe", 100f, 300f, 500f, 1100f, 400)
        val half = motion.frame(200, 0, 144)
        assertEquals(100f, half.startX, 0f)
        assertEquals(156f, half.startY, 0f)
        assertEquals(300f, half.x, 0f)
        assertEquals(556f, half.y, 0f)
        assertEquals(1f, half.alpha, 0f)
        assertEquals(750L, motion.lifetimeMs)
        val fade = motion.frame(575, 0, 144)
        assertEquals(500f, fade.x, 0f)
        assertEquals(956f, fade.y, 0f)
        assertEquals(0.5f, fade.alpha, 0f)
    }

    @Test fun landscapeAndInsetOriginsDoNotChangeDisplayCoordinates() {
        val motion = TrailMotion("swipe", 600f, 200f, 100f, 200f, 1000)
        val frame = motion.frame(500, 40, 24)
        assertEquals(310f, frame.x, 0f)
        assertEquals(176f, frame.y, 0f)
        assertEquals(560f, frame.startX, 0f)
    }

    @Test fun holdStaysAtThePointForTheActualDurationThenFades() {
        val motion = TrailMotion("long_press", 20f, 30f, 20f, 30f, 600)
        assertEquals(1f, motion.frame(600, 0, 0).alpha, 0f)
        assertEquals(0.5f, motion.frame(775, 0, 0).alpha, 0f)
        assertEquals(20f, motion.frame(775, 0, 0).x, 0f)
        assertEquals(0f, motion.frame(950, 0, 0).alpha, 0f)
    }

    @Test fun tapRippleAndEveryTrailHaveABoundedEnd() {
        val tap = TrailMotion("tap", 20f, 30f, 20f, 30f, 80)
        assertEquals(450L, tap.lifetimeMs)
        assertEquals(0.5f, tap.frame(225, 0, 0).ripple, 0f)
        for (method in listOf("tap", "long_press", "swipe")) {
            val motion = tap.copy(method = method)
            assertEquals(0f, motion.frame(Long.MAX_VALUE, 0, 0).alpha, 0f)
            assertEquals(1f, motion.frame(-1, 0, 0).alpha, 0f)
        }
    }

    @Test fun validationWaitsForTwoFramesAndExactOwnedWindowRemoval() {
        assertFalse(TrailSettlement.ready(0, false, 0))
        assertFalse(TrailSettlement.ready(1, false, 16))
        assertFalse(TrailSettlement.ready(2, true, 32))
        assertTrue(TrailSettlement.ready(2, false, 32))
    }

    @Test fun missingFramesOrFailedRemovalCannotStallAnRpc() {
        assertFalse(TrailSettlement.ready(0, true, 249))
        assertTrue(TrailSettlement.ready(0, true, 250))
        assertTrue(TrailSettlement.ready(100, true, 250))
    }

    @Test fun delayedOwnRemovalEventsDrainBeforeNewObservation() {
        assertFalse(TrailSettlement.ready(2, false, 32, 32, 50))
        assertFalse(TrailSettlement.ready(4, false, 64, 14, 50))
        assertTrue(TrailSettlement.ready(7, false, 112, 62, 50))
        assertTrue(TrailSettlement.ready(20, false, 250, 0, 50))
    }
}

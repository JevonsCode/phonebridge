package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent.*
import org.junit.Assert.*
import org.junit.Test

class LocalPhoneUseTest {
    private var now = 100L
    private val use = LocalPhoneUse({ now })
    private val manager = ControlLeaseManager({ now }, localUseActive = { use.active })
    private val a = java.util.UUID(0, 1).toString()
    private val b = java.util.UUID(0, 2).toString()
    private fun request(id: String) = manager.request("pc", 1, "PC", id, true, true) { _, _ -> true }
    private fun advance(settled: Boolean) = manager.advance(settled) { _, _ -> true }

    @Test fun gestureHoldAndFollowupActivityDelayFifoAndBlockLegacyInput() {
        use.begin(LocalPhoneUse.Touch.ACTIVITY)
        assertEquals("queued", request(a).state)
        assertEquals(2, request(b).position)
        assertEquals("CONTROL_BUSY", assertThrows(BridgeFailure::class.java) {
            manager.authorize("pc", 1, "PC", null)
        }.code)
        now += 20_000
        assertFalse(advance(true))
        use.end(LocalPhoneUse.Touch.ACTIVITY)
        now += 9_999
        use.activity()
        now += 9_999
        assertFalse(advance(true))
        now++
        assertTrue(advance(true))
        assertEquals(a, manager.lease!!.controlId)
    }

    @Test fun interruptedOwnerKeepsItsTurnButCannotReuseItsPreviousEpochOrTargets() {
        request(a)
        val old = manager.lease!!
        request(b)
        use.activity()
        manager.suspendForLocalUse()
        assertFalse(manager.valid(old))
        assertEquals("queued", manager.status("pc", 1, a).state)
        assertEquals(1, manager.status("pc", 1, b).position)
        assertEquals("CONTROL_QUEUED", assertThrows(BridgeFailure::class.java) {
            manager.authorize("pc", 1, "PC", a)
        }.code)
        assertEquals("CONTROL_QUEUED", assertThrows(BridgeFailure::class.java) { manager.renew("pc", 1, a) }.code)
        now += 10_000
        assertFalse(advance(false))
        assertTrue(advance(true))
        val resumed = manager.lease!!
        assertEquals(a, resumed.controlId)
        assertTrue(resumed.needsObservation)
        assertFalse(manager.valid(old))
        assertEquals("OBSERVATION_REQUIRED", assertThrows(BridgeFailure::class.java) { LocalPhoneUse.requireFreshTarget("tap") }.code)
        LocalPhoneUse.requireFreshTarget("state")
        manager.release("pc", 1, a)
        assertTrue(advance(true))
        assertEquals(b, manager.lease!!.controlId)
    }

    @Test fun cancelledPausedOwnerDoesNotReturnLaterOrConsumeAQueueSlot() {
        request(a)
        repeat(64) { request(java.util.UUID(1, it.toLong()).toString()) }
        use.activity()
        manager.suspendForLocalUse()
        assertEquals(64, manager.waitingCount)
        assertEquals(65, manager.pendingTaskCount)
        assertEquals("cancelled", manager.release("pc", 1, a).state)
        now += 10_000
        advance(true)
        assertEquals(java.util.UUID(1, 0).toString(), manager.lease!!.controlId)
    }

    @Test fun repeatedClickAfterOwnClickAndLongPressDoNotDisappearInTheEchoWindow() {
        use.expectFeedback("app", isGesture = true, eventTypes = TYPE_VIEW_LONG_CLICKED)
        assertFalse(use.accessibilityEvent(TYPE_TOUCH_INTERACTION_START, null, now))
        now += 600
        assertFalse(use.accessibilityEvent(TYPE_VIEW_LONG_CLICKED, "app", now))
        use.endRemoteGesture()
        assertFalse(use.accessibilityEvent(TYPE_TOUCH_INTERACTION_END, null, now))
        now++
        assertTrue(use.accessibilityEvent(TYPE_TOUCH_INTERACTION_START, null, now))
        now += 15_000
        assertTrue(use.active)
        use.accessibilityEvent(TYPE_TOUCH_INTERACTION_END, null, now)
        use.expectFeedback("app", eventTypes = TYPE_VIEW_CLICKED)
        assertFalse(use.accessibilityEvent(TYPE_VIEW_CLICKED, "app", now))
        assertTrue(use.accessibilityEvent(TYPE_VIEW_CLICKED, "app", now + 1))
    }

    @Test fun onlyExpectedAccessibilityFeedbackIsSuppressedAndRealEventsExtendTheQuietInterval() {
        use.expectFeedback("app", eventTypes = TYPE_VIEW_TEXT_CHANGED)
        assertFalse(use.accessibilityEvent(TYPE_VIEW_TEXT_CHANGED, "app", now))
        assertFalse(use.accessibilityEvent(TYPE_WINDOW_CONTENT_CHANGED, "app", now))
        assertTrue(use.accessibilityEvent(TYPE_VIEW_CLICKED, "app", now))
        use.expectFeedback("app", isGesture = true, eventTypes = TYPE_VIEW_SCROLLED)
        now += 2_000
        assertFalse(use.accessibilityEvent(TYPE_VIEW_SCROLLED, "app", now))
        assertTrue(use.accessibilityEvent(TYPE_VIEW_CLICKED, "other", now))
        use.endRemoteGesture()
        now += 600
        assertTrue(use.accessibilityEvent(TYPE_TOUCH_INTERACTION_START, null, now))
        now += 20_000
        assertTrue(use.active)
        assertTrue(use.accessibilityEvent(TYPE_TOUCH_INTERACTION_END, null, now))
        now += 9_999
        assertTrue(use.active)
        now++
        assertFalse(use.active)
    }
}

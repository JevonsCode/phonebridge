package dev.phonebridge.phonebridge

import dev.phonebridge.phonebridge.SessionNotificationPolicy.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionNotificationPolicyTest {
    private fun present(reconnecting: Boolean = false, connected: Boolean = true, actions: Boolean = false,
                        owner: String? = null, pending: Int = 0, local: Boolean = false, usb: Boolean = false) =
        SessionNotificationPolicy.present(reconnecting, connected, actions, owner, pending, local, usb)

    @Test fun onlyOngoingAiTasksRequestPromotion() {
        assertEquals(State.READ_ONLY, present().state)
        assertFalse(present().promote)
        assertEquals(State.ACTIONS, present(actions = true).state)
        assertFalse(present(actions = true).promote)
        assertEquals(State.CONTROLLING, present(owner = "Mac").state)
        assertTrue(present(owner = "Mac").promote)
        assertEquals(State.QUEUED, present(pending = 2).state)
        assertTrue(present(pending = 2).promote)
        assertEquals(State.LOCAL_USE, present(owner = "Mac", pending = 1, local = true).state)
        assertTrue(present(pending = 1, local = true).promote)
        assertFalse(present(local = true).promote)
    }

    @Test fun connectionStatesNeverPromote() {
        assertEquals(State.RECONNECTING, present(connected = false, reconnecting = true).state)
        assertEquals(State.CONNECTING, present(connected = false).state)
        assertFalse(present(connected = false, reconnecting = true, owner = "Mac").promote)
        // A second computer retrying does not hide the connected state of the first.
        assertEquals(State.CONTROLLING, present(reconnecting = true, owner = "Mac").state)
    }

    @Test fun usbIsReportedOnlyWhileConnected() {
        assertTrue(present(usb = true).viaUsb)
        assertFalse(present(connected = false, usb = true).viaUsb)
        assertEquals(65, present(pending = 400).waiting)
    }

    @Test fun promotionNeedsAndroid16Qpr1() {
        assertFalse(SessionNotificationPolicy.promotionApiAvailable(35, null))
        assertFalse(SessionNotificationPolicy.promotionApiAvailable(36, "36.0"))
        assertFalse(SessionNotificationPolicy.promotionApiAvailable(36, null))
        assertTrue(SessionNotificationPolicy.promotionApiAvailable(36, "36.1"))
        assertTrue(SessionNotificationPolicy.promotionApiAvailable(37, null))
    }
}

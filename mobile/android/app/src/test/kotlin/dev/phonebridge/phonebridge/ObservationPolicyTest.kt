package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ObservationPolicyTest {
    @Test fun contentAndCursorRefreshesKeepCurrentNodeIds() {
        assertFalse(ObservationPolicy.invalidatesNodeIds(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED))
        assertFalse(ObservationPolicy.invalidatesNodeIds(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED))
    }

    @Test fun windowScrollFocusAndTextChangesExpireCurrentNodeIds() {
        listOf(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED, AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED).forEach {
            assertTrue(ObservationPolicy.invalidatesNodeIds(it))
        }
    }
}

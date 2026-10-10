package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ObservationPolicyTest {
    @Test fun onlyContentRefreshOfVerifiedOutsideCropSystemWindowIsExcluded() {
        val outsideCropSystemIds = setOf(24)
        assertTrue(ObservationPolicy.isExcludedSystemRefresh(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, 24, outsideCropSystemIds))
        assertFalse(ObservationPolicy.isExcludedSystemRefresh(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, 25, outsideCropSystemIds))
        assertFalse(ObservationPolicy.isExcludedSystemRefresh(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, -1, outsideCropSystemIds))
        assertFalse(ObservationPolicy.isExcludedSystemRefresh(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, 24, emptySet()))
    }

    @Test fun structuralAndAppEventsCannotInheritSystemContentException() {
        listOf(AccessibilityEvent.TYPE_WINDOWS_CHANGED, AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED, AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED).forEach {
            assertFalse(ObservationPolicy.isExcludedSystemRefresh(it, 24, setOf(24)))
        }
    }

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

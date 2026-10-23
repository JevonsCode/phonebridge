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

    @Test fun contentRebindExpiresIdsEvenWhenRecycledChildButtonIsIdentical() {
        val observed = NodeActionPolicy.Target(7, "com.example.list", WindowGeometry.Bounds(10, 20, 100, 60),
            "android.widget.Button", "com.example.list:id/open", "Open", null)
        val reboundForAnotherItem = observed.copy()
        // Refreshing the child alone cannot establish which parent list item it now belongs to.
        NodeActionPolicy.requireUnchanged(observed, reboundForAnotherItem)
        assertTrue(ObservationPolicy.invalidatesNodeIds(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED))
        assertFalse(ObservationPolicy.isExcludedSystemRefresh(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, 7, setOf(24)))
    }

    @Test fun cursorOnlyRefreshKeepsCurrentNodeIds() {
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

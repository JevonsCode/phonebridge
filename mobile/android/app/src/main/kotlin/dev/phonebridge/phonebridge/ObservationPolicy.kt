package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent

object ObservationPolicy {
    fun isExcludedSystemRefresh(eventType: Int, windowId: Int, verifiedOutsideCropSystemIds: Set<Int>): Boolean =
        eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED && windowId >= 0 &&
            windowId in verifiedOutsideCropSystemIds

    fun invalidatesNodeIds(eventType: Int): Boolean = when (eventType) {
        AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
        AccessibilityEvent.TYPE_WINDOWS_CHANGED,
        AccessibilityEvent.TYPE_VIEW_SCROLLED,
        AccessibilityEvent.TYPE_VIEW_FOCUSED,
        AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
        AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> true
        // A recycled row can retain an identical child button while its logical item changes.
        // Verified system windows outside the capture and our own trail are filtered by the caller.
        else -> false
    }
}

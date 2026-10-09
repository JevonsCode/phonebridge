package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent

object ObservationPolicy {
    fun invalidatesNodeIds(eventType: Int): Boolean = when (eventType) {
        AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
        AccessibilityEvent.TYPE_WINDOWS_CHANGED,
        AccessibilityEvent.TYPE_VIEW_SCROLLED,
        AccessibilityEvent.TYPE_VIEW_FOCUSED,
        AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> true
        // Cursor/IME refreshes often emit CONTENT_CHANGED without changing the target.
        // set_text refreshes and verifies the cached target before dispatch instead.
        else -> false
    }
}

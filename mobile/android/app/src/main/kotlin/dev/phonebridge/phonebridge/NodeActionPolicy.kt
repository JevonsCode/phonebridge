package dev.phonebridge.phonebridge

/** Pure target identity and geometry checks for actions on an observed node. */
object NodeActionPolicy {
    val actions = setOf("click", "long_click", "scroll_forward", "scroll_backward", "focus", "paste", "copy", "cut", "select_all")

    data class Target(
        val windowId: Int,
        val packageName: String?,
        val bounds: WindowGeometry.Bounds,
        val className: String?,
        val resourceId: String?,
        val text: String?,
        val description: String?,
        val selected: Boolean = false,
        val checked: Boolean = false,
        val checkable: Boolean = false,
        val focused: Boolean = false,
        val stateDescription: String? = null,
        val editable: Boolean = false,
        val selectionStart: Int = -1,
        val selectionEnd: Int = -1,
    )

    fun requireUnchanged(observed: Target, current: Target) {
        if (observed != current) {
            throw BridgeFailure("STALE_NODE", "The target changed or moved. Request state again.")
        }
    }

    fun requireTextAction(action: String, editable: Boolean, focused: Boolean, textLength: Int,
                          selectionStart: Int, selectionEnd: Int) {
        if (action in setOf("paste", "cut") && (!editable || !focused)) {
            throw BridgeFailure("FOCUS_REQUIRED", "Paste and cut require a focused editable, non-password field.")
        }
        if (action in setOf("copy", "cut") && (minOf(selectionStart, selectionEnd) < 0 || selectionStart == selectionEnd ||
                maxOf(selectionStart, selectionEnd) > textLength)) {
            throw BridgeFailure("SELECTION_REQUIRED", "Select nonempty text first, for example with select_all, then request fresh state.")
        }
        if (action == "select_all" && textLength <= 0) {
            throw BridgeFailure("SELECTION_REQUIRED", "The target has no selectable text.")
        }
    }

    fun requireAction(action: String, supported: Set<String>, visible: Boolean, enabled: Boolean,
                      passwordAncestry: Boolean) {
        if (action !in actions) throw BridgeFailure("INVALID_ARGUMENT", "Unsupported node action.")
        if (passwordAncestry || !visible || !enabled) {
            throw BridgeFailure("NODE_BLOCKED", "Only visible, enabled, non-password nodes accept actions.")
        }
        if (action !in supported) throw BridgeFailure("ACTION_UNSUPPORTED", "The node does not support that action.")
    }

    /** Edge-to-edge app widgets may include system-bar padding; require a safe visible action area. */
    fun safeActionBounds(action: String, target: WindowGeometry.Bounds, safe: WindowGeometry.Bounds,
                         screen: WindowGeometry.Bounds, foreign: List<WindowGeometry.Bounds>): WindowGeometry.Bounds {
        // These actions address the already verified node, not a screen point.
        // Identity, visibility, password, selection/focus and authority checks
        // remain required by the caller even when a smart-text overlay is open.
        if (action in setOf("paste", "copy", "cut", "select_all")) return target
        fun nonempty(area: WindowGeometry.Bounds) = area.left < area.right && area.top < area.bottom
        fun contains(outer: WindowGeometry.Bounds, inner: WindowGeometry.Bounds) =
            outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom
        fun intersects(a: WindowGeometry.Bounds, b: WindowGeometry.Bounds) =
            a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top
        val scroll = action == "scroll_forward" || action == "scroll_backward"
        val centerX = target.left + (target.right - target.left) / 2
        val centerY = target.top + (target.bottom - target.top) / 2
        val safeCenter = centerX >= safe.left && centerX < safe.right && centerY >= safe.top && centerY < safe.bottom
        if (!nonempty(target) || !contains(screen, target) || (!scroll && !safeCenter)) {
            throw BridgeFailure("WINDOW_OBSCURED", "The node is outside the safe application area.")
        }
        val visible = WindowGeometry.Bounds(maxOf(target.left, safe.left), maxOf(target.top, safe.top),
            minOf(target.right, safe.right), minOf(target.bottom, safe.bottom))
        if (!nonempty(visible) || foreign.any { intersects(it, visible) }) {
            throw BridgeFailure("WINDOW_OBSCURED", "The node is obscured or outside the safe application area.")
        }
        return visible
    }
}

package dev.phonebridge.phonebridge

object ProtectedControlPolicy {
    const val PREFIX = "phonebridge.protected."
    fun isProtected(identifier: String?): Boolean = identifier?.let { it.startsWith(PREFIX) || it.substringAfterLast('/').startsWith(PREFIX) } == true

    fun requireNode(enabled: Boolean, ownApp: Boolean, target: WindowGeometry.Bounds, controls: List<WindowGeometry.Bounds>, action: String = "click") {
        // Native scrolling, selection and focus do not toggle descendant switches.
        if (action in setOf("scroll_forward", "scroll_backward", "focus", "copy", "select_all")) return
        if (enabled && ownApp && controls.any { intersects(target, it) }) blocked()
    }

    /** Segment/rectangle intersection also catches swipes whose endpoints lie outside a control. */
    fun requireGesture(enabled: Boolean, ownApp: Boolean, x1: Float, y1: Float, x2: Float, y2: Float,
                       controls: List<WindowGeometry.Bounds>) {
        if (enabled && ownApp && controls.any { touches(it, x1, y1, x2, y2) }) blocked()
    }

    private fun intersects(a: WindowGeometry.Bounds, b: WindowGeometry.Bounds) =
        a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top

    fun touches(area: WindowGeometry.Bounds, x1: Float, y1: Float, x2: Float, y2: Float): Boolean {
        var low = 0.0; var high = 1.0
        val dx = (x2 - x1).toDouble(); val dy = (y2 - y1).toDouble()
        val p = doubleArrayOf(-dx, dx, -dy, dy)
        val q = doubleArrayOf(x1.toDouble() - area.left, area.right - x1.toDouble(),
            y1.toDouble() - area.top, area.bottom - y1.toDouble())
        for (i in p.indices) {
            if (p[i] == 0.0) { if (q[i] < 0.0) return false; continue }
            val ratio = q[i] / p[i]
            if (p[i] < 0.0) low = maxOf(low, ratio) else high = minOf(high, ratio)
            if (low > high) return false
        }
        return true
    }

    private fun blocked(): Nothing = throw BridgeFailure("PROTECTED_CONTROL",
        "This PhoneBridge connection or permission control is protected. Use another target; only the owner can change this protection setting.")
}

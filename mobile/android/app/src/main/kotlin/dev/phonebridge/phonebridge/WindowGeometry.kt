package dev.phonebridge.phonebridge

/** Pixel geometry shared by screen capture and coordinate actions. */
object WindowGeometry {
    data class Bounds(val left: Int, val top: Int, val right: Int, val bottom: Int)
    data class Insets(val left: Int, val top: Int, val right: Int, val bottom: Int)

    /** Trim edge-attached occlusion; never include an overlay in the returned crop. */
    fun trimEdgeOcclusion(content: Bounds, overlay: Bounds): Bounds {
        if (overlay.left >= content.right || overlay.right <= content.left ||
            overlay.top >= content.bottom || overlay.bottom <= content.top) return content
        if (overlay.left <= content.left && overlay.right >= content.right) {
            if (overlay.top <= content.top && overlay.bottom < content.bottom)
                return content.copy(top = overlay.bottom)
            if (overlay.bottom >= content.bottom && overlay.top > content.top)
                return content.copy(bottom = overlay.top)
        }
        if (overlay.top <= content.top && overlay.bottom >= content.bottom) {
            if (overlay.left <= content.left && overlay.right < content.right)
                return content.copy(left = overlay.right)
            if (overlay.right >= content.right && overlay.left > content.left)
                return content.copy(right = overlay.left)
        }
        return content
    }

    fun safeApplicationBounds(screen: Bounds, app: Bounds, root: Bounds, bars: Insets): Bounds? {
        if (bars.left < 0 || bars.top < 0 || bars.right < 0 || bars.bottom < 0) return null
        if (screen.left >= screen.right || screen.top >= screen.bottom ||
            app.left >= app.right || app.top >= app.bottom ||
            root.left > root.right || root.top > root.bottom) return null
        // Some apps expose a nonvisual root container with zero area. The caller has
        // already matched its package/window ID to an OS TYPE_APPLICATION window.
        // Only that independently verified window may replace an empty root rectangle.
        val emptyRoot = root.left == root.right || root.top == root.bottom
        if (!emptyRoot && (root.left < app.left || root.top < app.top ||
                root.right > app.right || root.bottom > app.bottom)) return null
        val content = if (emptyRoot) app else root
        // Insets describe the display edges, never offsets to apply to the app's own bounds.
        val result = Bounds(
            maxOf(screen.left + bars.left, app.left, content.left),
            maxOf(screen.top + bars.top, app.top, content.top),
            minOf(screen.right - bars.right, app.right, content.right),
            minOf(screen.bottom - bars.bottom, app.bottom, content.bottom),
        )
        return result.takeIf { it.left < it.right && it.top < it.bottom }
    }
}

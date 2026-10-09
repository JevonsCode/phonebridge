package dev.phonebridge.phonebridge

/** Pixel geometry shared by screen capture and coordinate actions. */
object WindowGeometry {
    data class Bounds(val left: Int, val top: Int, val right: Int, val bottom: Int)
    data class Insets(val left: Int, val top: Int, val right: Int, val bottom: Int)

    fun safeApplicationBounds(screen: Bounds, app: Bounds, root: Bounds, bars: Insets): Bounds? {
        if (bars.left < 0 || bars.top < 0 || bars.right < 0 || bars.bottom < 0) return null
        // Insets describe the display edges, never offsets to apply to the app's own bounds.
        val result = Bounds(
            maxOf(screen.left + bars.left, app.left, root.left),
            maxOf(screen.top + bars.top, app.top, root.top),
            minOf(screen.right - bars.right, app.right, root.right),
            minOf(screen.bottom - bars.bottom, app.bottom, root.bottom),
        )
        return result.takeIf { it.left < it.right && it.top < it.bottom }
    }
}

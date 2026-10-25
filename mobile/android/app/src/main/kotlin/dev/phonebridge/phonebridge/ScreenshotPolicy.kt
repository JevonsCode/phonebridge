package dev.phonebridge.phonebridge

object ScreenshotPolicy {
    data class Window(val packageName: String, val windowId: Int, val crop: WindowGeometry.Bounds,
                      val screenWidth: Int, val screenHeight: Int)
    data class Frame(val id: String, val epoch: Long, val window: Window, val width: Int, val height: Int)

    fun point(frame: Frame?, id: String, imageX: Double, imageY: Double, epoch: Long, window: Window): Pair<Float, Float> {
        if (frame == null || frame.id != id || frame.epoch != epoch || frame.window != window) {
            throw BridgeFailure("STALE_SCREENSHOT", "The screenshot or application geometry changed. Capture a fresh screenshot before tapping.")
        }
        if (!imageX.isFinite() || !imageY.isFinite() || imageX < 0 || imageY < 0 ||
            imageX >= frame.width || imageY >= frame.height || frame.width <= 0 || frame.height <= 0) {
            throw BridgeFailure("OUT_OF_BOUNDS", "Image coordinates must be inside the returned screenshot dimensions.")
        }
        val crop = frame.window.crop
        return Pair((crop.left + imageX * (crop.right - crop.left) / frame.width).toFloat(),
            (crop.top + imageY * (crop.bottom - crop.top) / frame.height).toFloat())
    }
}

package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ScreenshotPolicyTest {
    private val window = ScreenshotPolicy.Window("allowed", 1, WindowGeometry.Bounds(0, 120, 1440, 3080), 1440, 3200)
    private val frame = ScreenshotPolicy.Frame("image", 10, window, 600, 1234)

    @Test fun imageCoordinatesUseTheReturnedCropAndActualScaledImageDimensions() {
        val point = ScreenshotPolicy.point(frame, "image", 300.0, 617.0, 10, window)
        assertEquals(720f, point.first, 0.001f)
        assertEquals(1600f, point.second, 0.001f)
    }

    @Test fun staleEpochCropWindowDisplayAndScreenshotIdAreRejected() {
        listOf(window.copy(crop = window.crop.copy(bottom = 1900)), window.copy(windowId = 2),
            window.copy(packageName = "other"), window.copy(screenWidth = 3200, screenHeight = 1440)).forEach {
            assertEquals("STALE_SCREENSHOT", assertThrows(BridgeFailure::class.java) { ScreenshotPolicy.point(frame, "image", 10.0, 10.0, 10, it) }.code)
        }
        assertEquals("STALE_SCREENSHOT", assertThrows(BridgeFailure::class.java) { ScreenshotPolicy.point(frame, "image", 10.0, 10.0, 11, window) }.code)
        assertEquals("STALE_SCREENSHOT", assertThrows(BridgeFailure::class.java) { ScreenshotPolicy.point(frame, "old", 10.0, 10.0, 10, window) }.code)
        assertEquals("STALE_SCREENSHOT", assertThrows(BridgeFailure::class.java) { ScreenshotPolicy.point(null, "image", 10.0, 10.0, 10, window) }.code)
    }

    @Test fun screenshotEdgesAndNonfiniteCoordinatesCannotEscapeTheCrop() {
        listOf(-1.0 to 0.0, 600.0 to 0.0, 0.0 to 1234.0, Double.NaN to 0.0, 0.0 to Double.POSITIVE_INFINITY).forEach {
            assertEquals("OUT_OF_BOUNDS", assertThrows(BridgeFailure::class.java) { ScreenshotPolicy.point(frame, "image", it.first, it.second, 10, window) }.code)
        }
    }
}

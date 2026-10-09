package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WindowGeometryTest {
    private val screen = WindowGeometry.Bounds(0, 0, 320, 640)
    private val bars = WindowGeometry.Insets(0, 24, 0, 40)

    @Test fun edgeToEdgeAppExcludesStatusAndNavigationStrips() {
        assertEquals(WindowGeometry.Bounds(0, 24, 320, 600),
            WindowGeometry.safeApplicationBounds(screen, screen, screen, bars))
    }

    @Test fun alreadyInsetAppIsNotInsetTwice() {
        val app = WindowGeometry.Bounds(0, 24, 320, 600)
        assertEquals(app, WindowGeometry.safeApplicationBounds(screen, app, app, bars))
    }

    @Test fun cropRespectsRootBoundsAndWindowOffsets() {
        val app = WindowGeometry.Bounds(30, 60, 290, 640)
        val root = WindowGeometry.Bounds(40, 80, 280, 620)
        assertEquals(WindowGeometry.Bounds(40, 80, 280, 600),
            WindowGeometry.safeApplicationBounds(screen, app, root, bars))
    }

    @Test fun landscapeNavigationUsesAbsoluteSideInset() {
        val landscape = WindowGeometry.Bounds(0, 0, 640, 320)
        assertEquals(WindowGeometry.Bounds(0, 24, 600, 320),
            WindowGeometry.safeApplicationBounds(landscape, landscape, landscape,
                WindowGeometry.Insets(0, 24, 40, 0)))
    }

    @Test fun statusOnlyMatchesObservedEmulatorGeometry() {
        assertEquals(WindowGeometry.Bounds(0, 24, 320, 640),
            WindowGeometry.safeApplicationBounds(screen, screen, screen, WindowGeometry.Insets(0, 24, 0, 0)))
    }

    @Test fun invalidOrEmptySafeAreaIsRefused() {
        assertNull(WindowGeometry.safeApplicationBounds(screen, screen, screen, WindowGeometry.Insets(0, 400, 0, 300)))
        assertNull(WindowGeometry.safeApplicationBounds(screen, screen, screen, WindowGeometry.Insets(-1, 0, 0, 0)))
        assertNull(WindowGeometry.safeApplicationBounds(screen, WindowGeometry.Bounds(0, 0, 320, 20), screen, bars))
    }
}

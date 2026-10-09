package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WindowGeometryTest {
    @Test fun actualPhoneBarsAndImeAreExcludedEvenWhenMetricsOmitInsets() {
        val phone = WindowGeometry.Bounds(0, 0, 1440, 3200)
        val statusTrim = WindowGeometry.trimEdgeOcclusion(phone, WindowGeometry.Bounds(0, 0, 1440, 144))
        val navTrim = WindowGeometry.trimEdgeOcclusion(statusTrim, WindowGeometry.Bounds(0, 3109, 1440, 3200))
        assertEquals(WindowGeometry.Bounds(0, 144, 1440, 3109), navTrim)
        assertEquals(WindowGeometry.Bounds(0, 144, 1440, 1981),
            WindowGeometry.trimEdgeOcclusion(navTrim, WindowGeometry.Bounds(0, 1981, 1440, 3200)))
    }

    @Test fun floatingPartialAndFullCoverOverlaysRemainForOverlapRefusal() {
        val content = WindowGeometry.Bounds(0, 100, 1440, 3000)
        for (overlay in listOf(WindowGeometry.Bounds(20, 100, 1420, 400),
            WindowGeometry.Bounds(0, 500, 1440, 900), WindowGeometry.Bounds(0, 0, 1440, 3200)))
            assertEquals(content, WindowGeometry.trimEdgeOcclusion(content, overlay))
    }

    @Test fun landscapeBarTrimsOnlyItsOwnSide() {
        assertEquals(WindowGeometry.Bounds(0, 0, 600, 320), WindowGeometry.trimEdgeOcclusion(
            WindowGeometry.Bounds(0, 0, 640, 320), WindowGeometry.Bounds(600, 0, 640, 320)))
    }
    private val screen = WindowGeometry.Bounds(0, 0, 320, 640)
    private val bars = WindowGeometry.Insets(0, 24, 0, 40)

    @Test fun emptyRootUsesVerifiedPhoneApplicationWindowWithSafeInsets() {
        val phone = WindowGeometry.Bounds(0, 0, 1440, 3200)
        assertEquals(WindowGeometry.Bounds(0, 144, 1440, 3109),
            WindowGeometry.safeApplicationBounds(phone, phone, WindowGeometry.Bounds(0, 0, 0, 0),
                WindowGeometry.Insets(0, 144, 0, 91)))
    }

    @Test fun emptyRootDoesNotExpandBeyondVerifiedApplicationWindow() {
        val app = WindowGeometry.Bounds(30, 60, 290, 620)
        assertEquals(WindowGeometry.Bounds(30, 60, 290, 600),
            WindowGeometry.safeApplicationBounds(screen, app, WindowGeometry.Bounds(0, 0, 0, 0), bars))
        assertNull(WindowGeometry.safeApplicationBounds(screen, WindowGeometry.Bounds(0, 0, 0, 0),
            WindowGeometry.Bounds(0, 0, 0, 0), bars))
    }

    @Test fun nonemptyOutsideOrInvertedRootNeverFallsBack() {
        for (root in listOf(WindowGeometry.Bounds(400, 0, 700, 640),
            WindowGeometry.Bounds(-1, 0, 320, 640), WindowGeometry.Bounds(0, 0, 321, 640),
            WindowGeometry.Bounds(20, 0, 10, 640))) {
            assertNull(WindowGeometry.safeApplicationBounds(screen, screen, root, bars))
        }
    }

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

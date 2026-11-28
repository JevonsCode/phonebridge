package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Test

class ControlIndicatorPolicyTest {
    @Test fun lineStaysInsideTheStatusBar() {
        assertEquals(10, ControlIndicatorPolicy.heightPx(2.625f, 144))
        assertEquals(6, ControlIndicatorPolicy.heightPx(1.5f, 6 ))
        assertEquals(3, ControlIndicatorPolicy.heightPx(3f, 3))
        assertEquals(0, ControlIndicatorPolicy.heightPx(3f, 0))
        assertEquals(2, ControlIndicatorPolicy.heightPx(0.25f, 100))
    }

    @Test fun indicatorIsOnByDefaultAndOtherDefaultsAreUnchanged() {
        assertEquals(true, AutomationPreferenceDefaults.value("showControlIndicator"))
        assertEquals(false, AutomationPreferenceDefaults.value("tapJitter"))
    }
}

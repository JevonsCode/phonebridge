package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ScreenAwakePolicyTest {
    @Test fun controllingNeedsARealLeaseAndRunningService() {
        assertTrue(ScreenAwakePolicy.shouldHold("controlling", true, true, true))
        assertFalse(ScreenAwakePolicy.shouldHold("controlling", true, false, true))
        assertFalse(ScreenAwakePolicy.shouldHold("controlling", false, true, true))
    }
    @Test fun alwaysWorksDisconnectedAndTeardownReleases() {
        assertTrue(ScreenAwakePolicy.shouldHold("always", true, false, true))
        assertFalse(ScreenAwakePolicy.shouldHold("always", false, false, true))
    }
    @Test fun offAndManualScreenLockAlwaysWin() {
        assertFalse(ScreenAwakePolicy.shouldHold("off", true, true, true))
        for (mode in ScreenAwakePolicy.modes) assertFalse(ScreenAwakePolicy.shouldHold(mode, true, true, false))
    }
}

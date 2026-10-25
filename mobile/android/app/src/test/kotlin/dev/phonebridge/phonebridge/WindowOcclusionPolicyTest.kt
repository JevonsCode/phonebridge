package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class WindowOcclusionPolicyTest {
    @Test fun onlyIdentifiedUnfocusedNoninteractiveToastsMayBeIgnoredForInput() {
        assertTrue(WindowOcclusionPolicy.isNonInteractiveToast(3, false, false, "android.widget.Toast", null, false))
        assertFalse(WindowOcclusionPolicy.isNonInteractiveToast(3, true, false, "android.widget.Toast", null, false))
        assertFalse(WindowOcclusionPolicy.isNonInteractiveToast(3, false, true, "android.widget.Toast", null, false))
        assertFalse(WindowOcclusionPolicy.isNonInteractiveToast(3, false, false, "android.widget.Toast", null, true))
        assertFalse(WindowOcclusionPolicy.isNonInteractiveToast(3, false, false, "android.widget.FrameLayout", null, false))
    }

    @Test fun diagnosticsDescribeOnlyPackageAndWindowKinds() {
        val details = WindowOcclusionPolicy.details("allowed", 2, "keyboard")
        assertEquals("keyboard", details["obscuredBy"])
        assertEquals("allowed", details["foregroundPackage"])
        assertEquals(2, details["windowType"])
        assertEquals(setOf("foregroundPackage", "windowType", "obscuredBy", "obscuringPackage"), details.keys)
        assertEquals("toast", WindowOcclusionPolicy.details("allowed", 3, "android", true)["obscuredBy"])
    }
}

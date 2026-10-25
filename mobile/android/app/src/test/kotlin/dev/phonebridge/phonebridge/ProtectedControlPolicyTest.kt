package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ProtectedControlPolicyTest {
    private val control = WindowGeometry.Bounds(100, 100, 200, 180)
    @Test fun rawFlutterIdentifiersAndQualifiedAndroidIdsAreRecognized() {
        assertTrue(ProtectedControlPolicy.isProtected("phonebridge.protected.actions"))
        assertTrue(ProtectedControlPolicy.isProtected("dev.phonebridge.phonebridge:id/phonebridge.protected.actions"))
        assertFalse(ProtectedControlPolicy.isProtected("phonebridge.files"))
        assertFalse(ProtectedControlPolicy.isProtected(null))
    }

    @Test fun clicksAndDescendantNodesInsideProtectedControlsAreBlocked() {
        assertEquals("PROTECTED_CONTROL", assertThrows(BridgeFailure::class.java) {
            ProtectedControlPolicy.requireGesture(true, true, 150f, 150f, 150f, 150f, listOf(control))
        }.code)
        assertEquals("PROTECTED_CONTROL", assertThrows(BridgeFailure::class.java) {
            ProtectedControlPolicy.requireNode(true, true, WindowGeometry.Bounds(110, 110, 140, 140), listOf(control))
        }.code)
    }

    @Test fun swipeCannotCrossProtectedControlsWithBothEndpointsOutside() {
        assertEquals("PROTECTED_CONTROL", assertThrows(BridgeFailure::class.java) {
            ProtectedControlPolicy.requireGesture(true, true, 0f, 140f, 300f, 140f, listOf(control))
        }.code)
        ProtectedControlPolicy.requireGesture(true, true, 0f, 90f, 300f, 90f, listOf(control))
        ProtectedControlPolicy.requireGesture(true, true, 0f, 0f, 90f, 300f, listOf(control))
    }

    @Test fun ownerCanDisableProtectionAndOtherAppsAreNotAffected() {
        ProtectedControlPolicy.requireGesture(false, true, 150f, 150f, 150f, 150f, listOf(control))
        ProtectedControlPolicy.requireGesture(true, false, 150f, 150f, 150f, 150f, listOf(control))
        ProtectedControlPolicy.requireNode(false, true, control, listOf(control))
        ProtectedControlPolicy.requireNode(true, false, control, listOf(control))
    }
    @Test fun scrollingAnAncestorDoesNotClickItsProtectedDescendants() {
        val container = WindowGeometry.Bounds(0, 0, 500, 1000)
        for (action in listOf("scroll_forward", "scroll_backward", "focus", "copy", "select_all")) {
            ProtectedControlPolicy.requireNode(true, true, container, listOf(control), action)
        }
        assertEquals("PROTECTED_CONTROL", assertThrows(BridgeFailure::class.java) {
            ProtectedControlPolicy.requireNode(true, true, container, listOf(control), "click")
        }.code)
    }
}

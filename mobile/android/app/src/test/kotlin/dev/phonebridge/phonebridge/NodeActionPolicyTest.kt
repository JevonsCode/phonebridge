package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class NodeActionPolicyTest {
    private val screen = WindowGeometry.Bounds(0, 0, 400, 800)
    private val safe = WindowGeometry.Bounds(0, 30, 400, 750)
    private val target = NodeActionPolicy.Target(12, "dev.allowed", WindowGeometry.Bounds(10, 40, 80, 90),
        "android.widget.Button", "dev.allowed:id/next", "Next", "Continue")

    @Test fun sameObservedTargetIsAccepted() {
        NodeActionPolicy.requireUnchanged(target, target.copy())
    }

    @Test fun recycledNodeWithDifferentIdentityIsStaleEvenAtSameCoordinates() {
        listOf(target.copy(windowId = 13), target.copy(packageName = "dev.other"),
            target.copy(className = "android.widget.EditText"), target.copy(resourceId = "dev.allowed:id/delete"),
            target.copy(text = "Delete"), target.copy(description = "Remove"),
            target.copy(selected = true), target.copy(checked = true),
            target.copy(checkable = true), target.copy(focused = true),
            target.copy(bounds = target.bounds.copy(left = 11))).forEach { changed ->
            assertFailure("STALE_NODE") { NodeActionPolicy.requireUnchanged(target, changed) }
        }
    }

    @Test fun eachRequestedActionMustBeSupportedByTheFreshNode() {
        NodeActionPolicy.actions.forEach { action ->
            NodeActionPolicy.requireAction(action, setOf(action), true, true, false)
            assertFailure("ACTION_UNSUPPORTED") {
                NodeActionPolicy.requireAction(action, emptySet(), true, true, false)
            }
        }
        assertFailure("INVALID_ARGUMENT") {
            NodeActionPolicy.requireAction("set_text", setOf("set_text"), true, true, false)
        }
    }

    @Test fun invisibleDisabledAndPasswordAncestorsBlockEvenSupportedActions() {
        assertFailure("NODE_BLOCKED") { NodeActionPolicy.requireAction("click", setOf("click"), false, true, false) }
        assertFailure("NODE_BLOCKED") { NodeActionPolicy.requireAction("click", setOf("click"), true, false, false) }
        assertFailure("NODE_BLOCKED") { NodeActionPolicy.requireAction("click", setOf("click"), true, true, true) }
    }

    @Test fun clickLongClickAndFocusRequireAVisibleSafeCenter() {
        for (action in listOf("click", "long_click", "focus")) {
            assertEquals(target.bounds, NodeActionPolicy.safeActionBounds(action, target.bounds, safe, screen, emptyList()))
            assertFailure("WINDOW_OBSCURED") {
                NodeActionPolicy.safeActionBounds(action, WindowGeometry.Bounds(0, 0, 400, 40), safe, screen, emptyList())
            }
        }
    }

    @Test fun bottomNavigationPaddingDoesNotBlockAnOtherwiseVisibleAppButton() {
        val button = WindowGeometry.Bounds(0, 700, 400, 790)
        assertEquals(WindowGeometry.Bounds(0, 700, 400, 750), NodeActionPolicy.safeActionBounds("click", button,
            safe, screen, listOf(WindowGeometry.Bounds(0, 750, 400, 800))))
        assertFailure("WINDOW_OBSCURED") {
            NodeActionPolicy.safeActionBounds("click", button, safe, screen, listOf(WindowGeometry.Bounds(0, 710, 400, 740)))
        }
    }

    @Test fun edgeToEdgeScrollContainerUsesOnlyVerifiedVisiblePart() {
        for (action in listOf("scroll_forward", "scroll_backward")) {
            assertEquals(safe, NodeActionPolicy.safeActionBounds(action, screen, safe, screen,
                listOf(WindowGeometry.Bounds(0, 0, 400, 30), WindowGeometry.Bounds(0, 750, 400, 800))))
        }
    }

    @Test fun clippedScrollStillRejectsForeignWindowCoveringItsVisiblePart() {
        assertFailure("WINDOW_OBSCURED") {
            NodeActionPolicy.safeActionBounds("scroll_forward", screen, safe, screen,
                listOf(WindowGeometry.Bounds(40, 500, 180, 600)))
        }
    }

    @Test fun scrollCannotUseOffScreenOrEmptyOrFullyExcludedNodes() {
        for (bounds in listOf(WindowGeometry.Bounds(-1, 0, 400, 800), WindowGeometry.Bounds(0, 0, 401, 800),
            WindowGeometry.Bounds(10, 10, 10, 20), WindowGeometry.Bounds(0, 0, 400, 30),
            WindowGeometry.Bounds(0, 750, 400, 800))) {
            assertFailure("WINDOW_OBSCURED") {
                NodeActionPolicy.safeActionBounds("scroll_backward", bounds, safe, screen, emptyList())
            }
        }
    }

    private fun assertFailure(code: String, block: () -> Unit) {
        assertEquals(code, assertThrows(BridgeFailure::class.java, block).code)
    }
}

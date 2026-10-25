package dev.phonebridge.phonebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SelectorPolicyTest {
    private val target = NodeActionPolicy.Target(1, "allowed", WindowGeometry.Bounds(10, 10, 90, 60),
        "android.widget.Button", "allowed:id/publish", "发布笔记", "分享笔记")

    @Test fun allProvidedExactAndContainsFiltersMustMatchTheCurrentNode() {
        assertTrue(NodeSelector(text = "发布笔记", descriptionContains = "分享", resourceId = "allowed:id/publish").matches(target))
        assertTrue(NodeSelector(textContains = "笔记", className = "android.widget.Button").matches(target))
        assertFalse(NodeSelector(text = "发布", description = "分享笔记").matches(target))
        assertFalse(NodeSelector(textContains = "笔记", resourceId = "allowed:id/delete").matches(target))
    }

    @Test fun indexCannotMatchByItselfAndUnknownOrMistypedFiltersAreRejected() {
        listOf(JSONObject(), JSONObject().put("index", 0), JSONObject().put("text", ""),
            JSONObject().put("text", 1), JSONObject().put("text", "发布").put("regex", true),
            JSONObject().put("text", "发布").put("index", -1), JSONObject().put("text", "发布").put("index", 0.5)).forEach {
            assertEquals("INVALID_ARGUMENT", assertThrows(BridgeFailure::class.java) { NodeSelector.parse(it) }.code)
        }
        assertTrue(NodeSelector.parse(JSONObject().put("text", "发布笔记")).matches(target))
    }

    @Test fun ambiguityNeverSilentlyChoosesTheFirstMatch() {
        val ambiguous = assertThrows(BridgeFailure::class.java) { SelectorPolicy.choose(NodeSelector(text = "发布"), 2) }
        assertEquals("AMBIGUOUS_SELECTOR", ambiguous.code)
        assertEquals(2, ambiguous.details["matchCount"])
        assertEquals(1, SelectorPolicy.choose(NodeSelector(text = "发布", index = 1), 2))
        assertEquals(0, SelectorPolicy.choose(NodeSelector(resourceId = "allowed:id/publish"), 1))
    }

    @Test fun missingOrOutOfRangeOrIncompleteSearchCannotDispatch() {
        assertEquals("SELECTOR_NOT_FOUND", assertThrows(BridgeFailure::class.java) { SelectorPolicy.choose(NodeSelector(text = "发布"), 0) }.code)
        assertEquals("SELECTOR_NOT_FOUND", assertThrows(BridgeFailure::class.java) { SelectorPolicy.choose(NodeSelector(text = "发布", index = 2), 2) }.code)
        assertEquals("SELECTOR_INCOMPLETE", assertThrows(BridgeFailure::class.java) { SelectorPolicy.choose(NodeSelector(text = "发布"), 1, true) }.code)
    }

    @Test fun tapTargetsRequireExactlyOneCompleteCoordinateOrSelectorMode() {
        assertEquals(SelectorPolicy.TapMode.PHYSICAL, SelectorPolicy.tapMode(setOf("x", "y")))
        assertEquals(SelectorPolicy.TapMode.SELECTOR, SelectorPolicy.tapMode(setOf("selector")))
        assertEquals(SelectorPolicy.TapMode.IMAGE, SelectorPolicy.tapMode(setOf("imageX", "imageY", "screenshotId")))
        listOf(emptySet(), setOf("x"), setOf("y"), setOf("imageX", "imageY"), setOf("screenshotId"),
            setOf("selector", "x", "y"), setOf("selector", "imageX", "imageY", "screenshotId")).forEach {
            assertEquals("INVALID_ARGUMENT", assertThrows(BridgeFailure::class.java) { SelectorPolicy.tapMode(it) }.code)
        }
    }
}

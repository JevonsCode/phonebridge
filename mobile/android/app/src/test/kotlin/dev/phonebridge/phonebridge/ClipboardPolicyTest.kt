package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ClipboardPolicyTest {
    @Test fun normalLinkAndUnicodeClipboardContentAreReturnedInOneRead() {
        val text = "https://example.com/分享?笔记=123😀"
        val result = ClipboardPolicy.result(text)
        assertEquals(text, result.getString("text"))
        assertTrue(result.getBoolean("hasText"))
        assertFalse(result.getBoolean("truncated"))
        assertEquals(text.length, result.getInt("totalLength"))
    }

    @Test fun emptyTextAndDisabledPreferenceDoNotPretendThereIsClipboardContent() {
        assertFalse(ClipboardPolicy.result("").getBoolean("hasText"))
        assertEquals("CLIPBOARD_DISABLED", assertThrows(BridgeFailure::class.java) { ClipboardPolicy.requireEnabled(false) }.code)
        ClipboardPolicy.requireEnabled(true)
    }

    @Test fun onlyExistingWireBudgetTruncatesVeryLargeTextWithoutBreakingSurrogates() {
        val text = "😀\"\n".repeat(600000)
        val result = ClipboardPolicy.result(text)
        val prefix = result.getString("text")
        assertTrue(result.getBoolean("truncated"))
        assertTrue(result.getBoolean("hasText"))
        assertEquals(text.length, result.getInt("totalLength"))
        assertTrue(text.startsWith(prefix))
        assertTrue(result.toString().toByteArray(Charsets.UTF_8).size <= ClipboardPolicy.RESULT_BUDGET_BYTES)
        assertFalse(Character.isHighSurrogate(prefix.last()))
    }
}

package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ClipboardReadLifecycleTest {
    private class Read {
        val events = mutableListOf<String>()
        var reads = 0
        var releases = 0
        var authority: String? = null
        var readError: Exception? = null
        var releaseError: Exception? = null
        var removed = true
        var onRead: () -> Unit = {}
        var onRelease: () -> Unit = {}
        val replies = mutableListOf<Pair<String?, BridgeFailure?>>()
        val lifecycle = FocusedOperationLifecycle({
            events += "validate"
            authority?.let { throw BridgeFailure(it, "Authority changed") }
        }, {
            events += "read"
            reads++
            onRead()
            readError?.let { throw it }
            "synthetic clipboard"
        }, {
            events += "release"
            releases++
            onRelease()
            releaseError?.let { throw it }
            removed
        }, ClipboardPolicy::focusFailure) { result, error ->
            events += "complete"
            replies += result to error
        }
    }

    @Test fun actualFocusReadsOnceAndRemovesWindowBeforeReturningContents() {
        val read = Read()
        read.lifecycle.focused(false)
        assertEquals(0, read.reads)
        assertTrue(read.replies.isEmpty())
        read.lifecycle.focused(true)
        read.lifecycle.focused(true)
        assertEquals(listOf("validate", "read", "release", "validate", "complete"), read.events)
        assertEquals("synthetic clipboard", read.replies.single().first)
        assertNull(read.replies.single().second)
        assertEquals(1, read.reads)
        assertEquals(1, read.releases)
        assertFalse(read.lifecycle.cleanupPending)
    }

    @Test fun focusTimeoutReleasesWithoutReadingOrInventingAnEmptyClipboard() {
        val read = Read()
        read.lifecycle.focused(false)
        read.lifecycle.fail(BridgeFailure("CLIPBOARD_UNAVAILABLE", "Focus timed out"))
        read.lifecycle.focused(true)
        assertEquals(0, read.reads)
        assertEquals(listOf("release", "complete"), read.events)
        assertNull(read.replies.single().first)
        assertEquals("CLIPBOARD_UNAVAILABLE", read.replies.single().second?.code)
    }

    @Test fun revokedAuthorityBeforeFocusNeverReadsAndPreservesTheActualError() {
        val read = Read().apply { authority = "CONTROL_EXPIRED" }
        read.lifecycle.focused(true)
        assertEquals(0, read.reads)
        assertEquals(1, read.releases)
        assertNull(read.replies.single().first)
        assertEquals("CONTROL_EXPIRED", read.replies.single().second?.code)
    }

    @Test fun waitingForFocusIsCancelledPromptlyWhenSavedClipboardAccessIsDisabled() {
        val read = Read()
        read.lifecycle.checkAuthority()
        read.authority = "CLIPBOARD_DISABLED"
        read.lifecycle.checkAuthority()
        read.lifecycle.focused(true)
        assertEquals(0, read.reads)
        assertEquals(1, read.releases)
        assertEquals("CLIPBOARD_DISABLED", read.replies.single().second?.code)
    }

    @Test fun authorityRevokedDuringWindowRemovalCannotReturnAlreadyReadContents() {
        val read = Read()
        read.onRelease = { read.authority = "CLIPBOARD_DISABLED" }
        read.lifecycle.focused(true)
        assertEquals(1, read.reads)
        assertNull(read.replies.single().first)
        assertEquals("CLIPBOARD_DISABLED", read.replies.single().second?.code)
        assertEquals("complete", read.events.last())
    }

    @Test fun cancellationAndLateFocusOrTimeoutCallbacksCompleteOnlyOnce() {
        val read = Read()
        read.lifecycle.fail(BridgeFailure("NO_SESSION", "Service ended"))
        read.lifecycle.focused(true)
        read.lifecycle.fail(BridgeFailure("CLIPBOARD_UNAVAILABLE", "Late timeout"))
        read.lifecycle.checkAuthority()
        assertEquals(0, read.reads)
        assertEquals(1, read.releases)
        assertEquals("NO_SESSION", read.replies.single().second?.code)
    }

    @Test fun clipboardReadExceptionStillReleasesTheWindowBeforeItsSingleError() {
        val read = Read().apply { readError = SecurityException("Synthetic platform refusal") }
        read.lifecycle.focused(true)
        assertEquals(listOf("validate", "read", "release", "complete"), read.events)
        assertNull(read.replies.single().first)
        assertEquals("CLIPBOARD_UNAVAILABLE", read.replies.single().second?.code)
    }

    @Test fun failedRemovalRetainsCleanupOwnershipAndWithholdsContentsUntilRemoved() {
        val read = Read().apply { removed = false }
        read.lifecycle.focused(true)
        assertTrue(read.lifecycle.finished)
        assertTrue(read.lifecycle.cleanupPending)
        assertNull(read.replies.single().first)
        assertEquals("CLIPBOARD_UNAVAILABLE", read.replies.single().second?.code)
        assertFalse(read.lifecycle.retryCleanup())
        assertTrue(read.lifecycle.cleanupPending)
        read.removed = true
        assertTrue(read.lifecycle.retryCleanup())
        assertFalse(read.lifecycle.cleanupPending)
        read.lifecycle.focused(true)
        assertEquals(1, read.reads)
        assertEquals(1, read.replies.size)
    }

    @Test fun removalExceptionRetainsOwnershipForRetryAndDoesNotDeliverAgain() {
        val read = Read().apply { releaseError = IllegalStateException("Synthetic delayed removal") }
        read.lifecycle.focused(true)
        assertTrue(read.lifecycle.cleanupPending)
        assertNull(read.replies.single().first)
        read.releaseError = null
        assertTrue(read.lifecycle.retryCleanup())
        assertEquals(1, read.replies.size)
        assertEquals(2, read.releases)
    }

    @Test fun reentrantFocusAndDetachCallbacksCannotRepeatReadOrReplaceItsOutcome() {
        val read = Read()
        read.onRead = { read.lifecycle.focused(true) }
        read.onRelease = { read.lifecycle.fail(BridgeFailure("CLIPBOARD_UNAVAILABLE", "Removal caused detachment")) }
        read.lifecycle.focused(true)
        assertEquals(1, read.reads)
        assertEquals(1, read.releases)
        assertEquals("synthetic clipboard", read.replies.single().first)
        assertNull(read.replies.single().second)
    }
}

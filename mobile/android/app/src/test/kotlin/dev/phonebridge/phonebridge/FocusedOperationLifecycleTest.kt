package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

/** Non-clipboard operations use their own authority and failures, with no clipboard preference. */
class FocusedOperationLifecycleTest {
    private class Launch {
        var dispatches = 0
        var releases = 0
        var removed = true
        var validate: () -> Unit = {}
        var onDispatch: () -> Unit = {}
        var onRelease: () -> Unit = {}
        val replies = mutableListOf<Pair<Unit?, BridgeFailure?>>()
        val lifecycle = FocusedOperationLifecycle({ validate() }, {
            dispatches++
            onDispatch()
        }, {
            releases++
            onRelease()
            removed
        }, { stage -> BridgeFailure("ACTION_REJECTED", "Synthetic launch failure: $stage") }) { result, error ->
            replies += result to error
        }
    }

    @Test fun launchWaitsForVerifiedWindowAndDispatchesOnceDespiteRepeatedFocusCallbacks() {
        val launch = Launch()
        launch.lifecycle.focused(false)
        assertEquals(0, launch.dispatches)
        assertTrue(launch.replies.isEmpty())
        launch.onDispatch = { launch.lifecycle.focused(true) }
        launch.lifecycle.focused(true)
        launch.lifecycle.focused(true)
        launch.lifecycle.fail(BridgeFailure("ACTION_REJECTED", "Late timeout"))
        assertEquals(1, launch.dispatches)
        assertEquals(1, launch.releases)
        assertEquals(Unit, launch.replies.single().first)
        assertNull(launch.replies.single().second)
    }

    @Test fun mutationLeaseRevokedWhileWaitingPreventsAnyIntentDispatch() {
        val launch = Launch()
        launch.lifecycle.checkAuthority()
        launch.validate = { throw BridgeFailure("CONTROL_EXPIRED", "Original task ended") }
        launch.lifecycle.checkAuthority()
        launch.lifecycle.focused(true)
        assertEquals(0, launch.dispatches)
        assertEquals(1, launch.releases)
        assertNull(launch.replies.single().first)
        assertEquals("CONTROL_EXPIRED", launch.replies.single().second?.code)
    }

    @Test fun targetAuthorizationIsRecheckedAtFocusAndOriginalRejectionIsPreserved() {
        for (code in listOf("PACKAGE_BLOCKED", "PROTECTED_APP", "READ_ONLY")) {
            val launch = Launch()
            launch.lifecycle.checkAuthority()
            launch.validate = { throw BridgeFailure(code, "Target or mutation authority changed") }
            launch.lifecycle.focused(true)
            assertEquals(code, 0, launch.dispatches)
            assertNull(launch.replies.single().first)
            assertEquals(code, launch.replies.single().second?.code)
        }
    }

    @Test fun dispatchExceptionAndCleanupRetryNeverReplayAnUncertainIntent() {
        val launch = Launch().apply {
            removed = false
            onDispatch = { throw SecurityException("Synthetic platform launch rejection") }
        }
        launch.lifecycle.focused(true)
        assertEquals(1, launch.dispatches)
        assertTrue(launch.lifecycle.cleanupPending)
        assertNull(launch.replies.single().first)
        assertEquals("ACTION_REJECTED", launch.replies.single().second?.code)
        assertFalse(launch.lifecycle.retryCleanup())
        launch.removed = true
        assertTrue(launch.lifecycle.retryCleanup())
        launch.lifecycle.focused(true)
        assertEquals(1, launch.dispatches)
        assertEquals(1, launch.replies.size)
    }

    @Test fun postDispatchRevocationWithholdsSuccessButDoesNotRepeatTheMutation() {
        val launch = Launch()
        launch.onRelease = { launch.validate = { throw BridgeFailure("CONTROL_EXPIRED", "Task ended during cleanup") } }
        launch.lifecycle.focused(true)
        launch.lifecycle.focused(true)
        assertEquals(1, launch.dispatches)
        assertEquals(1, launch.releases)
        assertNull(launch.replies.single().first)
        assertEquals("CONTROL_EXPIRED", launch.replies.single().second?.code)
    }

    @Test fun focusTimeoutPreventsLateIntentDispatchAndKeepsLaunchFailureCode() {
        val launch = Launch()
        launch.lifecycle.fail(BridgeFailure("ACTION_REJECTED", "Focus timed out"))
        launch.lifecycle.focused(true)
        assertEquals(0, launch.dispatches)
        assertEquals(1, launch.releases)
        assertNull(launch.replies.single().first)
        assertEquals("ACTION_REJECTED", launch.replies.single().second?.code)
    }
}

package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectPolicyTest {
    @Test fun observationTimeoutReconnectsButNeverReplaysOrResumesUncertainMutations() {
        for (method in listOf("state", "screenshot")) assertTrue(ReconnectPolicy.timedOutReadCanReconnect(method))
        for (method in listOf("tap", "swipe", "set_text", "commit_text", "launch_app", "global_action", "unknown"))
            assertFalse(ReconnectPolicy.timedOutReadCanReconnect(method))
    }
    @Test fun transientServerFailuresAndOldSocketConflictCanRetryButBadCredentialsPause() {
        for (status in listOf(null, 408, 409, 425, 429, 500, 502, 503)) {
            assertFalse(ReconnectPolicy.isPermanentHttpRejection(status))
        }
        for (status in listOf(400, 401, 403, 404, 426)) {
            assertTrue(ReconnectPolicy.isPermanentHttpRejection(status))
        }
    }

    @Test fun ordinaryNetworkAndServiceLossPreserveOwnerResumePermission() {
        for (reason in listOf(ReconnectPolicy.EndReason.NETWORK, ReconnectPolicy.EndReason.SERVICE_UNAVAILABLE)) {
            assertTrue(ReconnectPolicy.resumeAllowedAfterEnd(true, reason))
            assertFalse(ReconnectPolicy.resumeAllowedAfterEnd(false, reason))
        }
    }

    @Test fun ownerStopUnknownOutcomeAndRevokedAuthorizationPauseSavedTrust() {
        for (reason in listOf(ReconnectPolicy.EndReason.OWNER_STOP, ReconnectPolicy.EndReason.TIMEOUT,
            ReconnectPolicy.EndReason.PROTOCOL, ReconnectPolicy.EndReason.AUTHENTICATION,
            ReconnectPolicy.EndReason.NOTIFICATIONS)) {
            assertFalse(ReconnectPolicy.resumeAllowedAfterEnd(true, reason))
        }
    }

    @Test fun retryRequiresSavedTrustResumePermissionAndLiveService() {
        assertTrue(ReconnectPolicy.shouldReconnect(true, true, true))
        assertFalse(ReconnectPolicy.shouldReconnect(false, true, true))
        assertFalse(ReconnectPolicy.shouldReconnect(true, false, true))
        assertFalse(ReconnectPolicy.shouldReconnect(true, true, false))
    }

    @Test fun exponentialBackoffIsBoundedAtThirtySeconds() {
        assertEquals(listOf(2000L, 4000L, 8000L, 16000L, 30000L, 30000L),
            (0..5).map { ReconnectPolicy.delayMillis(it) })
        assertEquals(30000L, ReconnectPolicy.delayMillis(Int.MAX_VALUE))
    }
}

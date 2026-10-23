package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class TransportLifecyclePolicyTest {
    @Test fun oldMutationTimeoutCannotPauseReplacementComputerButStillSettlesOldFence() {
        val manager = ControlLeaseManager({ 1000L })
        val scope = SessionOperationScope()
        val oldSocket = Any()
        val replacementSocket = Any()
        manager.acquire("computer", 1, "Computer", "00000000-0000-4000-8000-000000000001")
        scope.begin("old-mutation")
        val generation = scope.generation
        manager.disconnect("computer", 1)
        scope.invalidate()
        val replacement = manager.acquire("computer", 2, "Computer", "00000000-0000-4000-8000-000000000002")
        if (TransportLifecyclePolicy.isCurrent(1, 2, oldSocket, replacementSocket)) manager.revoke("computer")
        assertTrue(manager.valid(replacement))
        assertFalse(scope.begin("replacement-mutation"))
        assertTrue(scope.complete("old-mutation", generation))
        assertTrue(scope.begin("replacement-mutation"))
        assertTrue(manager.valid(replacement))
    }
    @Test fun socketReplacementAndMissingTransportRejectOldCallbacks() {
        val oldSocket = Any()
        assertTrue(TransportLifecyclePolicy.isCurrent(1, 1, oldSocket, oldSocket))
        assertFalse(TransportLifecyclePolicy.isCurrent(1, 1, oldSocket, Any()))
        assertFalse(TransportLifecyclePolicy.isCurrent(1, null, oldSocket, null))
        assertFalse(TransportLifecyclePolicy.isCurrent(1, 2, oldSocket, oldSocket))
    }
}

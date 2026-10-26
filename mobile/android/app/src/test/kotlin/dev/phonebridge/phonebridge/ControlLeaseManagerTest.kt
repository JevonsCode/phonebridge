package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class ControlLeaseManagerTest {
    private var time = 1000L
    private val manager = ControlLeaseManager({ time })
    private val a = "00000000-0000-4000-8000-000000000001"
    private val b = "00000000-0000-4000-8000-000000000002"
    private fun fails(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") } catch (e: BridgeFailure) { assertEquals(code, e.code) }
    }

    @Test fun explicitTaskMustAcquireAndCompetingComputerCannotStealIt() {
        fails("CONTROL_EXPIRED") { manager.authorize("A", 1, "Work", a) }
        val owner = manager.acquire("A", 1, "Work", a)
        fails("CONTROL_BUSY") { manager.acquire("B", 2, "Home", b) }
        fails("CONTROL_BUSY") { manager.authorize("A", 1, "Work", null) }
        assertSame(owner, manager.authorize("A", 1, "Work", a))
    }
    @Test fun leaseUsesIdleClockAndNetworkSilenceCannotExtendIt() {
        val lease = manager.acquire("A", 1, "A", a)
        time += 59_000
        assertTrue(manager.valid(lease))
        manager.authorize("A", 1, "A", a)
        time += 59_999
        assertTrue(manager.valid(lease))
        time++
        assertTrue(manager.expire())
        fails("CONTROL_EXPIRED") { manager.acquire("A", 1, "A", a) }
        assertNotNull(manager.acquire("B", 2, "B", b))
    }
    @Test fun releaseAndDisconnectAreTerminalEvenAfterReconnect() {
        manager.acquire("A", 1, "A", a)
        manager.release("A", 1, a)
        fails("CONTROL_EXPIRED") { manager.acquire("A", 1, "A", a) }
        manager.acquire("A", 1, "A", b)
        manager.disconnect("A", 1)
        fails("CONTROL_EXPIRED") { manager.acquire("A", 3, "A", b) }
    }
    @Test fun selectingAnotherComputerPreservesTheActiveTaskAndItsDeadline() {
        val owner = manager.acquire("A", 1, "A", a)
        val deadline = owner.deadline
        time += 10_000
        manager.select("B")
        assertSame(owner, manager.lease)
        assertTrue(manager.valid(owner))
        assertEquals(deadline, owner.deadline)
        assertSame(owner, manager.authorize("A", 1, "A", a))
        assertEquals("queued", manager.request("B", 2, "B", b, true, true) { _, _ -> true }.state)
    }
    @Test fun selectingAnIdleComputerDoesNotReserveThePhoneFromTheFirstRequester() {
        manager.select("B")
        val owner = manager.acquire("A", 1, "A", a)
        manager.disconnect("B", 2)
        assertTrue(manager.valid(owner))
        fails("CONTROL_BUSY") { manager.acquire("B", 2, "B", b) }
    }
    @Test fun expiryWhileExecutingDoesNotOpenExecutorFence() {
        val scope = SessionOperationScope()
        val lease = manager.acquire("A", 1, "A", a)
        assertTrue(scope.begin("old"))
        val executing = scope.generation
        time += 60_000
        assertFalse(manager.valid(lease))
        scope.invalidate()
        fails("BUSY") { scope.requireIdle(); manager.acquire("B", 2, "B", b) }
        assertNull(manager.lease)
        assertEquals(executing, scope.generation)
        assertFalse(scope.begin("new"))
        assertFalse(scope.isCurrent(executing))
        assertTrue(scope.complete("old", executing))
        scope.requireIdle()
        manager.acquire("B", 2, "B", b)
        assertTrue(scope.begin("new"))
        assertFalse(scope.complete("old", executing))
    }
    @Test fun reconnectGivesLegacyNewIdentityButCannotReviveOldExplicitTask() {
        manager.authorize("A", 1, "A", null)
        manager.disconnect("A", 1)
        assertNotNull(manager.authorize("A", 1, "A", null))
        manager.disconnect("A", 1)
        assertNotNull(manager.authorize("A", 2, "A", null))
    }
    @Test fun legacyCanStartFreshAfterIdleExpiryOnSameTransport() {
        val first = manager.authorize("A", 1, "A", null)
        time += 60_000
        assertTrue(manager.expire())
        val next = manager.authorize("A", 1, "A", null)
        assertNotSame(first, next)
        assertFalse(manager.valid(first))
    }
    @Test fun malformedControlIdNeverAcquires() {
        for (id in listOf("", "legacy", "1-1-1-1-1")) fails("INVALID_ARGUMENT") { manager.acquire("A", 1, "A", id) }
        assertNull(manager.lease)
    }
    @Test fun uuidLetterCaseCannotReviveARetiredTask() {
        val id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        manager.acquire("A", 1, "A", id.uppercase())
        manager.release("A", 1, id)
        fails("CONTROL_EXPIRED") { manager.acquire("A", 2, "A", id.uppercase()) }
    }
    @Test fun retiredTaskLimitFailsClosedRatherThanRevivingAnOldId() {
        val bounded = ControlLeaseManager({ time }, maximumRetired = 1)
        bounded.acquire("A", 1, "A", a)
        bounded.release("A", 1, a)
        fails("CONTROL_EXPIRED") { bounded.acquire("A", 2, "A", a) }
        fails("TASK_LIMIT") { bounded.acquire("A", 2, "A", b) }
        assertNull(bounded.lease)
    }
    @Test fun unboundedInjectorQueueCannotAdmitNewMutationAfterTimeoutOrLongDelay() {
        val scope = SessionOperationScope()
        manager.acquire("A", 1, "A", a)
        scope.begin("old")
        val old = scope.generation
        scope.markGestureDispatched(old)
        scope.invalidate()
        manager.disconnect("A", 1)
        try { scope.requireIdle(); fail("Expected pending gesture diagnostic") }
        catch (error: BridgeFailure) { assertEquals(OperationTimeoutPolicy.awaitingGestureMessage, error.message) }
        for (elapsed in listOf(12_000L, 60_000L, 3_600_000L)) {
            time += elapsed
            assertFalse(scope.canSettleOnTimeout())
            assertTrue(scope.awaitingGestureSettlement)
            fails("BUSY") { scope.requireIdle(); manager.acquire("B", 2, "B", b) }
            assertFalse(scope.begin("new"))
            assertNull(manager.lease)
        }
        // Only Android's actual completion/cancellation callback acknowledges the old gesture.
        assertTrue(scope.complete("old", old))
        assertFalse(scope.awaitingGestureSettlement)
        scope.requireIdle()
        manager.acquire("B", 2, "B", b)
        assertTrue(scope.begin("new"))
        assertFalse(scope.complete("old", old))
        assertFalse(scope.isCurrent(old))
    }
    @Test fun readOnlyAndNeverDispatchedDelayedCallsCanSettleOnTimeout() {
        for (id in listOf("screenshot", "state", "delayed-tap-not-dispatched")) {
            val scope = SessionOperationScope()
            scope.begin(id)
            val old = scope.generation
            scope.invalidate()
            assertTrue(scope.canSettleOnTimeout())
            assertTrue(scope.complete(id, old))
            scope.requireIdle()
            assertTrue(scope.begin("new"))
            // A late beforeRpc callback cannot dispatch after this authority change.
            assertFalse(scope.isCurrent(old))
            scope.markGestureDispatched(old)
            scope.invalidate()
            assertTrue(scope.canSettleOnTimeout())
        }
    }
    @Test fun arbitrationDiagnosticsAreBoundedAndContainNoCommandContent() {
        repeat(100) { manager.select("computer") }
        assertEquals(64, manager.events().size)
        assertTrue(manager.events().all { it.event == "selected" && it.computerId == "computer" })
    }
    @Test fun renewalExtendsOnlyTheExistingActiveTask() {
        val owner = manager.acquire("A", 1, "A", a)
        time += 59_000
        val renewed = manager.renew("A", 1, a)
        assertEquals("active", renewed.state)
        assertEquals(60_000L, renewed.expiresInMs)
        time += 59_999
        assertTrue(manager.valid(owner))
        time++
        fails("CONTROL_EXPIRED") { manager.renew("A", 1, a) }
        assertNull(manager.lease)
    }
    @Test fun waitingOrDifferentConnectionsCannotRenewTheOwnersLease() {
        val owner = manager.acquire("A", 1, "A", a)
        manager.request("B", 2, "B", b, true, true) { _, _ -> true }
        val deadline = owner.deadline
        time += 5_000
        fails("CONTROL_QUEUED") { manager.renew("B", 2, b) }
        fails("CONTROL_EXPIRED") { manager.renew("A", 3, a) }
        assertEquals(deadline, owner.deadline)
        assertSame(owner, manager.lease)
    }
}

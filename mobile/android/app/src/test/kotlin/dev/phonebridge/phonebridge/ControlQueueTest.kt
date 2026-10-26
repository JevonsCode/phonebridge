package dev.phonebridge.phonebridge

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class ControlQueueTest {
    private var time = 0L
    private val manager = ControlLeaseManager({ time })
    private val live = mutableSetOf("A" to 1L, "B" to 2L, "C" to 3L, "D" to 4L)
    private val isLive: (String, Long) -> Boolean = { id, connection -> id to connection in live }
    private fun id(n: Long) = UUID(0, n).toString()
    private fun request(computer: String, connection: Long, task: Long, queue: Boolean = true, settled: Boolean = true) =
        manager.request(computer, connection, computer, id(task), queue, settled, isLive)
    private fun advance(settled: Boolean = true) = manager.advance(settled, isLive)
    private fun fails(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") } catch (error: BridgeFailure) { assertEquals(code, error.code) }
    }

    @Test fun competingTasksQueueInFifoOrderAndDuplicateDoesNotJumpOrRenew() {
        assertEquals("active", request("A", 1, 1).state)
        assertEquals(1, request("B", 2, 2).position)
        assertEquals(2, request("C", 3, 3).position)
        time = 100_000
        assertEquals(1, request("B", 2, 2, settled = false).position)
        assertEquals(2, manager.waitingCount)
        // A expired, but the pending executor still prevents promotion.
        fails("CONTROL_BUSY") { request("D", 4, 4, queue = false) }
        // Existing B has FIFO priority and is granted before the new nonqueued caller can act.
        assertEquals(id(2), manager.lease!!.controlId)
    }
    @Test fun releaseGrantsNextAndPushesOnlyToItsOriginatingConnection() {
        request("A", 1, 1); request("B", 2, 2); request("C", 3, 3)
        manager.drainControlEvents()
        assertEquals("released", manager.release("A", 1, id(1)).state)
        advance()
        val events = manager.drainControlEvents()
        assertEquals(listOf("A", "B"), events.filter { it.state == "released" || it.state == "active" }.map { it.computerId })
        val granted = events.single { it.state == "active" }
        assertEquals("B", granted.computerId); assertEquals(2L, granted.connection); assertEquals(id(2), granted.controlId)
        assertEquals(1, events.last { it.controlId == id(3) }.position)
        manager.release("B", 2, id(2)); advance()
        assertEquals(id(3), manager.lease!!.controlId)
    }
    @Test fun statusRenewsOnlyWaitingTicketAndNeverTheActiveLease() {
        request("A", 1, 1); request("B", 2, 2)
        time = 59_000
        assertEquals("active", manager.status("A", 1, id(1)).state)
        assertEquals(1000L, request("A", 1, 1).expiresInMs) // Also management, not an observation.
        assertEquals(60_000L, manager.lease!!.deadline)
        manager.status("B", 2, id(2))
        time = 60_000
        advance()
        assertEquals(id(2), manager.lease!!.controlId)
        assertTrue(manager.drainControlEvents().any { it.controlId == id(1) && it.state == "expired" })
    }
    @Test fun repeatedQueuedAcquireCannotKeepAnOrphanTicketAlive() {
        request("A", 1, 1); request("B", 2, 2)
        time = 119_000
        request("B", 2, 2, settled = false)
        time = 120_000
        advance(false)
        assertEquals(0, manager.waitingCount)
        fails("CONTROL_EXPIRED") { manager.status("B", 2, id(2)) }
        fails("CONTROL_EXPIRED") { request("B", 2, 2) }
        assertTrue(manager.drainControlEvents().any { it.controlId == id(2) && it.state == "expired" })
    }
    @Test fun liveWaitCheckExtendsTicketWithoutProlongingOwner() {
        request("A", 1, 1); request("B", 2, 2)
        time = 119_000
        assertEquals("queued", manager.status("B", 2, id(2)).state)
        time = 200_000
        advance(false)
        assertEquals(1, manager.waitingCount)
        advance()
        assertEquals(id(2), manager.lease!!.controlId)
    }
    @Test fun acceptedGestureRequiresActualCallbackBeforeQueueCanGrant() {
        val scope = SessionOperationScope()
        request("A", 1, 1)
        scope.begin("gesture"); val generation = scope.generation
        scope.markGestureDispatched(generation)
        request("B", 2, 2, settled = false)
        manager.release("A", 1, id(1)); scope.invalidate()
        for (elapsed in listOf(12_000L, 60_000L, 110_000L)) {
            time = elapsed
            manager.status("B", 2, id(2))
            advance(scope.pending == null)
            assertNull(manager.lease)
            assertFalse(scope.canSettleOnTimeout())
        }
        assertTrue(scope.complete("gesture", generation))
        advance(scope.pending == null)
        assertEquals(id(2), manager.lease!!.controlId)
    }
    @Test fun localSelectionCannotInterruptTheOwnerOrMoveAComputerAheadOfTheQueue() {
        request("A", 1, 1); request("B", 2, 2); request("C", 3, 3)
        val owner = manager.lease
        manager.drainControlEvents()
        manager.select("C")
        advance()
        assertSame(owner, manager.lease)
        assertEquals(2, manager.waitingCount)
        assertTrue(manager.drainControlEvents().isEmpty())
        manager.release("A", 1, id(1)); advance()
        assertEquals(id(2), manager.lease!!.controlId)
        assertEquals(1, manager.waitingCount)
        manager.release("B", 2, id(2)); advance()
        assertEquals(id(3), manager.lease!!.controlId)
    }
    @Test fun selectingANonRequestingComputerNeverDelaysFifoHandoff() {
        request("A", 1, 1); request("B", 2, 2)
        manager.select("D"); advance()
        assertEquals(id(1), manager.lease!!.controlId)
        manager.release("A", 1, id(1)); advance()
        assertEquals(id(2), manager.lease!!.controlId)
        assertEquals(0L, time)
    }
    @Test fun selectingAComputerDuringAnAcceptedGesturePreservesAuthorityUntilCompletion() {
        val scope = SessionOperationScope()
        request("A", 1, 1); request("B", 2, 2)
        val owner = manager.lease!!
        assertTrue(scope.begin("gesture"))
        val generation = scope.generation
        scope.markGestureDispatched(generation)
        manager.select("B")
        advance(scope.pending == null)
        assertTrue(manager.valid(owner))
        assertTrue(scope.isCurrent(generation))
        assertEquals(1, manager.waitingCount)
        assertTrue(scope.complete("gesture", generation))
        manager.release("A", 1, id(1)); advance(scope.pending == null)
        assertEquals(id(2), manager.lease!!.controlId)
    }
    @Test fun disconnectAndQueuedReleaseCancelOnlyMatchingTickets() {
        request("A", 1, 1); request("B", 2, 2); request("B", 2, 3); request("C", 3, 4)
        assertEquals("cancelled", manager.release("B", 2, id(2)).state)
        assertEquals(2, manager.waitingCount)
        manager.disconnect("B", 99) // Stale connection teardown cannot cancel the live ticket.
        assertEquals(2, manager.waitingCount)
        manager.disconnect("B", 2)
        assertEquals(1, manager.waitingCount)
        fails("CONTROL_EXPIRED") { request("B", 2, 3) }
        manager.release("A", 1, id(1)); advance()
        assertEquals(id(4), manager.lease!!.controlId)
    }
    @Test fun liveConnectionGenerationChangeDropsWaiterAndCannotReviveUuid() {
        request("A", 1, 1); request("B", 2, 2)
        live.remove("B" to 2L); live.add("B" to 5L)
        fails("CONTROL_EXPIRED") { request("B", 5, 2) }
        assertEquals(0, manager.waitingCount)
        assertTrue(manager.drainControlEvents().any { it.controlId == id(2) && it.connection == 2L && it.state == "cancelled" })
    }
    @Test fun queuedTaskCannotExecuteOrImplicitlyReacquire() {
        request("A", 1, 1); request("B", 2, 2)
        fails("CONTROL_QUEUED") { manager.authorize("B", 2, "B", id(2)) }
        fails("CONTROL_QUEUED") { manager.requireExistingControl("B", 2, id(2)) }
        fails("CONTROL_BUSY") { manager.authorize("B", 2, "B", null) }
        assertEquals(1, manager.waitingCount)
        assertEquals(id(1), manager.lease!!.controlId)
    }
    @Test fun queueIsBoundedAndStopRetiresAllCancelledTickets() {
        request("A", 1, 1)
        repeat(64) { request("B", 2, it + 2L) }
        assertEquals(64, manager.waitingCount)
        fails("QUEUE_FULL") { request("C", 3, 100) }
        manager.clear()
        assertEquals(0, manager.waitingCount); assertNull(manager.lease)
        fails("CONTROL_EXPIRED") { request("B", 2, 2) }
        assertTrue(manager.events().any { it.event == "cancelled" })
    }
}

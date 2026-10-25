package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class FileReceiveQueueTest {
    @Test fun failedPreferenceCommitRestoresPreviousValueAndDoesNotStartPendingFiles() {
        val queue = FileReceiveQueue(false)
        queue.offer("waiting", 1)
        var stored = false
        assertThrows(IllegalStateException::class.java) {
            queue.setAutoReceiveEnabled(true) { value -> stored = value; false }
        }
        assertFalse(stored)
        assertFalse(queue.autoReceiveEnabled)
        assertNull(queue.nextAutomatic())
    }

    @Test fun successfulPreferenceCommitIsReadBackByANewQueue() {
        val queue = FileReceiveQueue()
        var stored = true
        queue.setAutoReceiveEnabled(false) { value -> stored = value; true }
        assertFalse(queue.autoReceiveEnabled)
        assertFalse(FileReceiveQueue(stored).autoReceiveEnabled)
    }

    @Test fun automaticReceptionIsOnByDefaultAndProcessesOffersInOrder() {
        val queue = FileReceiveQueue()
        assertTrue(queue.autoReceiveEnabled)
        repeat(150) { queue.offer("file-$it", 1) }
        repeat(150) {
            val transfer = queue.nextAutomatic()!!
            assertEquals("file-$it", transfer.id)
            assertEquals(1L, transfer.generation)
            assertNull(queue.nextAutomatic())
            assertTrue(queue.finish(transfer))
        }
        assertNull(queue.nextAutomatic())
    }

    @Test fun savedDisabledPreferenceKeepsManualReceptionAvailable() {
        val queue = FileReceiveQueue(false)
        queue.offer("first", 1)
        queue.offer("second", 1)
        assertFalse(queue.autoReceiveEnabled)
        assertNull(queue.nextAutomatic())
        val manual = queue.receive("second")!!
        assertEquals("second", manual.id)
        assertNull(queue.receive("first"))
        assertTrue(queue.finish(manual))
        assertNull(queue.nextAutomatic())
        assertEquals("first", queue.receive("first")!!.id)
    }

    @Test fun enablingReceptionContinuesExistingPendingOffers() {
        val queue = FileReceiveQueue(false)
        queue.offer("first", 1)
        queue.offer("second", 2)
        queue.setAutoReceiveEnabled(true)
        val first = queue.nextAutomatic()!!
        assertEquals("first", first.id)
        assertTrue(queue.finish(first))
        assertEquals("second", queue.nextAutomatic()!!.id)
    }

    @Test fun disablingReceptionLetsTheActiveTransferFinishAndPausesTheRest() {
        val queue = FileReceiveQueue()
        queue.offer("active", 1)
        queue.offer("waiting", 1)
        val active = queue.nextAutomatic()!!
        queue.setAutoReceiveEnabled(false)
        assertTrue(queue.isCurrent(active))
        assertTrue(queue.finish(active))
        assertNull(queue.nextAutomatic())
        queue.setAutoReceiveEnabled(true)
        assertEquals("waiting", queue.nextAutomatic()!!.id)
    }

    @Test fun failedTransferReleasesTheSlotWithoutAnImplicitRetry() {
        val queue = FileReceiveQueue()
        queue.offer("fails", 1)
        queue.offer("next", 1)
        val failed = queue.nextAutomatic()!!
        assertTrue(queue.finish(failed))
        val next = queue.nextAutomatic()!!
        assertEquals("next", next.id)
        assertFalse(queue.finish(failed))
        assertTrue(queue.isCurrent(next))
    }

    @Test fun disconnectingAnotherSourcePreservesTheActiveDownload() {
        val queue = FileReceiveQueue()
        queue.offer("active", 1)
        queue.offer("disconnected", 2)
        queue.offer("kept", 3)
        val active = queue.nextAutomatic()!!
        assertNull(queue.disconnected(2))
        assertTrue(queue.isCurrent(active))
        assertTrue(queue.finish(active))
        assertEquals("kept", queue.nextAutomatic()!!.id)
    }

    @Test fun disconnectingActiveSourceCancelsOnlyItsOffersAndContinuesOtherSources() {
        val queue = FileReceiveQueue()
        queue.offer("active", 1)
        queue.offer("same-source", 1)
        queue.offer("other-source", 2)
        val active = queue.nextAutomatic()!!
        assertSame(active, queue.disconnected(1))
        assertFalse(queue.isCurrent(active))
        val replacement = queue.nextAutomatic()!!
        assertEquals("other-source", replacement.id)
        assertFalse(queue.finish(active))
        assertTrue(queue.isCurrent(replacement))
    }

    @Test fun lateCompletionCannotSettleAReplacementWithTheSameFileId() {
        val queue = FileReceiveQueue()
        queue.offer("file", 1)
        val old = queue.nextAutomatic()!!
        queue.disconnected(1)
        queue.offer("file", 2)
        val replacement = queue.nextAutomatic()!!
        assertFalse(queue.finish(old))
        assertTrue(queue.isCurrent(replacement))
        assertEquals(2L, replacement.generation)
        assertNull(queue.nextAutomatic())
    }

    @Test fun declinedOrExpiredOffersAreSkippedWithoutAffectingTheActiveTransfer() {
        val queue = FileReceiveQueue()
        queue.offer("active", 1)
        queue.offer("declined", 1)
        queue.offer("expired", 1)
        queue.offer("next", 1)
        val active = queue.nextAutomatic()!!
        assertTrue(queue.removePending("declined"))
        assertTrue(queue.removePending("expired"))
        assertFalse(queue.removePending("active"))
        assertTrue(queue.isCurrent(active))
        queue.finish(active)
        assertEquals("next", queue.nextAutomatic()!!.id)
    }

    @Test fun disconnectingEverythingClearsTheQueueAndRejectsLateCallbacks() {
        val queue = FileReceiveQueue()
        queue.offer("active", 1)
        queue.offer("waiting", 2)
        val active = queue.nextAutomatic()!!
        assertSame(active, queue.disconnected())
        assertFalse(queue.finish(active))
        assertNull(queue.nextAutomatic())
        assertNull(queue.receive("waiting"))
    }
}

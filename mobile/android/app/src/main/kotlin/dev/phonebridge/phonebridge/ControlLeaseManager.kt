package dev.phonebridge.phonebridge

import java.util.UUID

/** Main-thread arbitration. Only real commands renew leases; only wait checks renew tickets. */
class ControlLeaseManager(private val now: () -> Long, private val idleMillis: Long = 60_000,
    private val maximumRetired: Int = 16_384, private val queueIdleMillis: Long = 120_000) {
    data class Lease(val computerId: String, val connection: Long, val controlId: String?, val name: String,
        val epoch: Long, var deadline: Long)
    data class Event(val event: String, val computerId: String, val elapsedMillis: Long)
    data class ControlEvent(val computerId: String, val connection: Long, val controlId: String,
        val state: String, val position: Int? = null, val ownerName: String? = null)
    data class TaskStatus(val controlId: String, val state: String, val position: Int? = null,
        val ownerName: String? = null, val expiresInMs: Long? = null)
    private data class Ticket(val computerId: String, val connection: Long, val controlId: String,
        val name: String, var deadline: Long, var lastPosition: Int = 0, var lastOwnerName: String? = null)
    private val eventLog = ArrayDeque<Event>()
    private val pushes = ArrayDeque<ControlEvent>()
    private val waiters = mutableListOf<Ticket>()
    val waitingCount: Int get() = waiters.size
    fun events(): List<Event> = eventLog.toList()
    fun drainControlEvents(): List<ControlEvent> = pushes.toList().also { pushes.clear() }
    private fun record(event: String, id: String) {
        if (eventLog.size == 64) eventLog.removeFirst()
        eventLog.addLast(Event(event, id, now()))
    }
    private fun push(id: String, connection: Long, controlId: String, state: String, position: Int? = null) {
        if (pushes.size == 256) pushes.removeFirst()
        pushes.addLast(ControlEvent(id, connection, controlId, state, position, lease?.name))
    }
    private fun positions() { waiters.forEachIndexed { index, t ->
        if (t.lastPosition != index + 1 || t.lastOwnerName != lease?.name) {
            push(t.computerId, t.connection, t.controlId, "queued", index + 1)
            t.lastPosition = index + 1; t.lastOwnerName = lease?.name
        }
    } }
    private var serial = 0L
    private val retired = mutableSetOf<String>()
    private var reservation: Pair<String, Long>? = null
    var lease: Lease? = null
        private set
    private fun key(id: String, connection: Long, control: String?) =
        if (control == null) "$id/$connection/legacy" else "$id/$control"
    private fun retire(reason: String) {
        val previous = lease
        lease = null
        serial++
        previous?.let {
            if (it.controlId != null) {
                retired.add(key(it.computerId, it.connection, it.controlId))
                push(it.computerId, it.connection, it.controlId, when (reason) {
                    "released" -> "released"
                    "expired", "handoff" -> "expired"
                    else -> "cancelled"
                })
            }
            record(reason, it.computerId)
        }
    }
    private fun removeTickets(reason: String, matches: (Ticket) -> Boolean): Boolean {
        val removed = waiters.filter(matches)
        waiters.removeAll(removed.toSet())
        removed.forEach {
            retired.add(key(it.computerId, it.connection, it.controlId))
            push(it.computerId, it.connection, it.controlId, reason)
            record(reason, it.computerId)
        }
        if (removed.isNotEmpty()) positions()
        return removed.isNotEmpty()
    }
    fun expire(): Boolean {
        var changed = lease?.let { now() >= it.deadline } == true
        if (changed) retire("expired")
        if (reservation?.let { now() >= it.second } == true) { reservation = null; changed = true }
        return removeTickets("expired") { now() >= it.deadline } || changed
    }
    fun select(computerId: String) {
        retire("handoff"); reservation = computerId to now() + idleMillis
        record("reserved", computerId); positions()
    }
    fun disconnect(computerId: String, connection: Long) {
        if (lease?.let { it.computerId == computerId && it.connection == connection } == true) retire("disconnected")
        removeTickets("cancelled") { it.computerId == computerId && it.connection == connection }
    }
    fun revoke(computerId: String) {
        if (lease?.computerId == computerId) retire("revoked")
        if (reservation?.first == computerId) reservation = null
        removeTickets("cancelled") { it.computerId == computerId }
    }
    fun clear() { retire("stopped"); reservation = null; removeTickets("cancelled") { true } }
    private fun requireCapacity() {
        if (retired.size + waiters.size + (if (lease?.controlId != null) 1 else 0) >= maximumRetired)
            throw BridgeFailure("TASK_LIMIT", "Control task limit reached. Restart PhoneBridge locally before acquiring a new task.")
    }
    private fun reservedForOther(id: String) = reservation?.first?.let { it != id } == true
    private fun ownerBusy(): Nothing = throw BridgeFailure("CONTROL_BUSY", lease?.let { "Control is held by ${it.name}." }
        ?: "Control is reserved or another task is waiting.")
    fun acquire(computerId: String, connection: Long, name: String, controlId: String): Lease =
        claim(computerId, connection, name, validateId(controlId), true)
    fun authorize(computerId: String, connection: Long, name: String, controlId: String?): Lease {
        val normalized = controlId?.let(::validateId)
        expire()
        if (normalized != null) rejectQueuedAction(computerId, connection, normalized)
        return claim(computerId, connection, name, normalized, false)
    }
    private fun rejectQueuedAction(id: String, connection: Long, controlId: String) {
        if (waiters.any { it.computerId == id && it.connection == connection && it.controlId == controlId })
            throw BridgeFailure("CONTROL_QUEUED", "This task is waiting for control and cannot observe or act yet.")
    }
    /** No acquire or lease renewal: used while the shared executor is fenced. */
    fun requireExistingControl(computerId: String, connection: Long, controlId: String) {
        val normalized = validateId(controlId)
        expire()
        rejectQueuedAction(computerId, connection, normalized)
        val owner = lease
        if (owner == null || owner.computerId != computerId || owner.connection != connection || owner.controlId != normalized) expired()
    }
    private fun claim(id: String, connection: Long, name: String, control: String?, acquire: Boolean): Lease {
        expire()
        if (key(id, connection, control) in retired) expired()
        val current = lease
        if (current != null) {
            if (current.computerId != id || current.connection != connection || current.controlId != control) ownerBusy()
            current.deadline = now() + idleMillis
            return current
        }
        if (control != null && !acquire) expired()
        if (reservedForOther(id) || waiters.any { !reservedForOther(it.computerId) }) ownerBusy()
        if (control != null) requireCapacity()
        return grant(id, connection, name, control)
    }
    private fun grant(id: String, connection: Long, name: String, control: String?): Lease {
        reservation = null
        return Lease(id, connection, control, name, ++serial, now() + idleMillis).also {
            lease = it; record("acquired", id)
            if (control != null) push(id, connection, control, "active")
        }
    }
    /** The caller supplies executor settlement and exact live connection identity. No command is replayed. */
    fun advance(executorSettled: Boolean, isLive: (String, Long) -> Boolean): Boolean {
        expire()
        lease?.let { if (!isLive(it.computerId, it.connection)) retire("disconnected") }
        removeTickets("cancelled") { !isLive(it.computerId, it.connection) }
        if (lease != null || !executorSettled) return false
        val next = waiters.indexOfFirst { !reservedForOther(it.computerId) }
        if (next < 0) return false
        val t = waiters.removeAt(next)
        grant(t.computerId, t.connection, t.name, t.controlId)
        positions()
        return true
    }
    fun request(computerId: String, connection: Long, name: String, controlId: String, queue: Boolean,
                executorSettled: Boolean, isLive: (String, Long) -> Boolean): TaskStatus {
        val normalized = validateId(controlId)
        expire()
        if (key(computerId, connection, normalized) in retired) expired()
        advance(executorSettled, isLive)
        if (key(computerId, connection, normalized) in retired) expired()
        // Repeating acquire is idempotent and does not keep an orphan task/ticket alive.
        lease?.takeIf { it.computerId == computerId && it.connection == connection && it.controlId == normalized }
            ?.let { return TaskStatus(normalized, "active", ownerName = it.name, expiresInMs = it.deadline - now()) }
        waiters.indexOfFirst { it.computerId == computerId && it.connection == connection && it.controlId == normalized }
            .takeIf { it >= 0 }?.let { return TaskStatus(normalized, "queued", it + 1, lease?.name, waiters[it].deadline - now()) }
        if (lease == null && executorSettled && !reservedForOther(computerId) && waiters.none { !reservedForOther(it.computerId) }) {
            requireCapacity()
            grant(computerId, connection, name, normalized)
            return TaskStatus(normalized, "active", ownerName = name, expiresInMs = idleMillis)
        }
        if (!queue) {
            if (!executorSettled) throw BridgeFailure("BUSY", OperationTimeoutPolicy.awaitingGestureMessage)
            ownerBusy()
        }
        if (waiters.size >= 64) throw BridgeFailure("QUEUE_FULL", "At most 64 tasks can wait for control.")
        requireCapacity()
        waiters.add(Ticket(computerId, connection, normalized, name, now() + queueIdleMillis))
        record("queued", computerId); positions()
        return TaskStatus(normalized, "queued", waiters.size, lease?.name, queueIdleMillis)
    }
    fun status(computerId: String, connection: Long, controlId: String): TaskStatus {
        val normalized = validateId(controlId)
        expire()
        lease?.takeIf { it.computerId == computerId && it.connection == connection && it.controlId == normalized }
            ?.let { return TaskStatus(normalized, "active", ownerName = it.name, expiresInMs = it.deadline - now()) }
        val index = waiters.indexOfFirst { it.computerId == computerId && it.connection == connection && it.controlId == normalized }
        if (index < 0) expired()
        waiters[index].deadline = now() + queueIdleMillis
        return TaskStatus(normalized, "queued", index + 1, lease?.name, queueIdleMillis)
    }
    fun release(id: String, connection: Long, controlId: String): TaskStatus {
        val normalized = validateId(controlId)
        expire()
        if (removeTickets("cancelled") { it.computerId == id && it.connection == connection && it.controlId == normalized })
            return TaskStatus(normalized, "cancelled")
        val current = lease
        if (current == null || current.computerId != id || current.connection != connection || current.controlId != normalized) expired()
        retire("released")
        return TaskStatus(normalized, "released")
    }
    fun renew(computerId: String, connection: Long, controlId: String): TaskStatus {
        val normalized = validateId(controlId)
        expire()
        rejectQueuedAction(computerId, connection, normalized)
        val held = lease?.takeIf { it.computerId == computerId && it.connection == connection && it.controlId == normalized }
            ?: expired()
        held.deadline = now() + idleMillis
        return TaskStatus(normalized, "active", ownerName = held.name, expiresInMs = idleMillis)
    }
    fun valid(expected: Lease): Boolean { expire(); return lease === expected }
    private fun validateId(id: String): String {
        if (id.length != 36 || try { UUID.fromString(id).toString() != id.lowercase() } catch (_: Exception) { true })
            throw BridgeFailure("INVALID_ARGUMENT", "controlId must be a UUID.")
        return id.lowercase()
    }
    private fun expired(): Nothing = throw BridgeFailure("CONTROL_EXPIRED", "This control task has ended. Acquire a new task explicitly.")
}

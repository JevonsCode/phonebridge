package dev.phonebridge.phonebridge

/** Main-thread FIFO. A transfer's identity fences callbacks from a disconnected source. */
class FileReceiveQueue(initialAutoReceiveEnabled: Boolean = true) {
    private data class Offer(val id: String, val generation: Long)
    class Transfer internal constructor(val id: String, val generation: Long)

    private var automatic = initialAutoReceiveEnabled
    val autoReceiveEnabled: Boolean get() = automatic
    var active: Transfer? = null
        private set
    private val pending = mutableListOf<Offer>()

    fun setAutoReceiveEnabled(enabled: Boolean, persist: (Boolean) -> Boolean = { true }) {
        val previous = automatic
        try {
            check(persist(enabled)) { "Could not save automatic file reception preference." }
        } catch (error: Exception) {
            // SharedPreferences may change its in-memory value even when commit fails.
            runCatching { persist(previous) }
            throw error
        }
        automatic = enabled
    }

    fun offer(id: String, generation: Long) {
        require(active?.id != id && pending.none { it.id == id }) { "Duplicate file offer." }
        pending.add(Offer(id, generation))
    }

    fun nextAutomatic(): Transfer? = if (autoReceiveEnabled && active == null) {
        pending.firstOrNull()?.let { receive(it.id) }
    } else null

    /** Manual reception stays available when automatic reception is disabled. */
    fun receive(id: String): Transfer? {
        if (active != null) return null
        val position = pending.indexOfFirst { it.id == id }
        if (position < 0) return null
        val offer = pending.removeAt(position)
        return Transfer(offer.id, offer.generation).also { active = it }
    }

    fun isCurrent(transfer: Transfer): Boolean = active === transfer

    /** Success and failure both release the slot; failed offers are never retried implicitly. */
    fun finish(transfer: Transfer): Boolean {
        if (!isCurrent(transfer)) return false
        active = null
        return true
    }

    fun removePending(id: String): Boolean = pending.removeAll { it.id == id }

    /** Returns only the interrupted transfer so callers never cancel another computer's download. */
    fun disconnected(generation: Long? = null): Transfer? {
        pending.removeAll { generation == null || it.generation == generation }
        val interrupted = active?.takeIf { generation == null || it.generation == generation }
        if (interrupted != null) active = null
        return interrupted
    }
}

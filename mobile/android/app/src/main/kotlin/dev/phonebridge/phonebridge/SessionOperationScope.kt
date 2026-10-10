package dev.phonebridge.phonebridge

/** Main-thread disposable RPC scope. Switching transports invalidates every old completion. */
class SessionOperationScope {
    var generation = 0L
        private set
    var pending: String? = null
        private set

    fun begin(id: String): Boolean {
        if (pending != null) return false
        pending = id
        return true
    }

    fun complete(id: String, expectedGeneration: Long): Boolean {
        if (generation != expectedGeneration || pending != id) return false
        pending = null
        return true
    }

    fun invalidate() {
        generation++
        pending = null
    }
}

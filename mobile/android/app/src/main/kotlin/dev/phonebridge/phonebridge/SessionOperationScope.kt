package dev.phonebridge.phonebridge

/** Phone-global executor fence. Revocation invalidates authority, never the in-flight fence. */
class SessionOperationScope {
    var generation = 0L
        private set
    var pending: String? = null
        private set
    private var valid = false
    private var gestureDispatched = false
    val awaitingGestureSettlement: Boolean get() = pending != null && gestureDispatched && !valid

    fun begin(id: String): Boolean {
        if (pending != null) return false
        generation++
        pending = id
        valid = true
        gestureDispatched = false
        return true
    }

    fun complete(id: String, expectedGeneration: Long): Boolean {
        if (generation != expectedGeneration || pending != id) return false
        pending = null
        valid = false
        gestureDispatched = false
        generation++
        return true
    }

    fun invalidate() {
        valid = false
        if (pending == null) generation++
    }

    /** Opening an unprotected editor changes the screen, not the executing task's authority. */
    fun invalidateForOwnerAuthorization(blocked: Boolean): Boolean {
        if (!blocked) return false
        invalidate()
        return true
    }

    fun isCurrent(expectedGeneration: Long) = pending != null && valid && generation == expectedGeneration

    fun markGestureDispatched(expectedGeneration: Long) {
        if (pending != null && generation == expectedGeneration) gestureDispatched = true
    }

    fun canSettleOnTimeout() = OperationTimeoutPolicy.canSettleOnTimeout(gestureDispatched)

    fun requireIdle() {
        if (pending != null) throw BridgeFailure("BUSY", if (awaitingGestureSettlement)
            OperationTimeoutPolicy.awaitingGestureMessage else "One operation is still settling. Observe before retrying.")
    }
}

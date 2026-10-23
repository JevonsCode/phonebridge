package dev.phonebridge.phonebridge

/** Android may queue gesture injection after accepting it. Only its callback proves settlement. */
object OperationTimeoutPolicy {
    const val awaitingGestureMessage = "Android has not confirmed that the previous gesture ended. Control remains blocked until Android reports completion or cancellation."
    fun canSettleOnTimeout(gestureDispatched: Boolean): Boolean = !gestureDispatched
}

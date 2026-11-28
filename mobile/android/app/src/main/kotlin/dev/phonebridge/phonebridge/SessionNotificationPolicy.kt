package dev.phonebridge.phonebridge

/**
 * Chooses what the connection notification says. Only an ongoing, owner-started AI task
 * (controlling, queued, or paused for local use with tasks waiting) requests Android's
 * promoted "Live Update" treatment; an idle connection stays an ordinary low-priority notice.
 */
object SessionNotificationPolicy {
    enum class State { RECONNECTING, CONNECTING, LOCAL_USE, CONTROLLING, QUEUED, ACTIONS, READ_ONLY }

    data class Presentation(val state: State, val promote: Boolean, val waiting: Int, val ownerName: String, val viaUsb: Boolean)

    fun present(reconnecting: Boolean, connected: Boolean, actionsEnabled: Boolean, controllingOwner: String?,
                pendingTasks: Int, localUseActive: Boolean, viaUsb: Boolean): Presentation {
        val waiting = pendingTasks.coerceIn(0, 65)
        val state = when {
            !connected && reconnecting -> State.RECONNECTING
            !connected -> State.CONNECTING
            localUseActive && waiting > 0 -> State.LOCAL_USE
            controllingOwner != null -> State.CONTROLLING
            waiting > 0 -> State.QUEUED
            actionsEnabled -> State.ACTIONS
            else -> State.READ_ONLY
        }
        val promote = state == State.CONTROLLING || state == State.QUEUED || state == State.LOCAL_USE
        return Presentation(state, promote, waiting, controllingOwner.orEmpty(), viaUsb && connected)
    }

    /** Android 16 QPR1 (API 36.1) introduced promotion; earlier builds render it as a normal notice. */
    fun promotionApiAvailable(sdkInt: Int, sdkFull: String?): Boolean {
        if (sdkInt > 36) return true
        if (sdkInt < 36) return false
        val minor = sdkFull?.substringAfter('.', "")?.toIntOrNull() ?: 0
        return minor >= 1
    }
}

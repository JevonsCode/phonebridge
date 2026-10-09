package dev.phonebridge.phonebridge

object ReconnectPolicy {
    fun timedOutReadCanReconnect(method: String) = method == "state" || method == "screenshot"
    enum class EndReason { NETWORK, SERVICE_UNAVAILABLE, OWNER_STOP, PROTOCOL, TIMEOUT, AUTHENTICATION, NOTIFICATIONS }

    fun permitsAutomaticResume(reason: EndReason) =
        reason == EndReason.NETWORK || reason == EndReason.SERVICE_UNAVAILABLE

    fun shouldReconnect(hasPairing: Boolean, resumeAllowed: Boolean, hasService: Boolean) =
        hasPairing && resumeAllowed && hasService

    fun resumeAllowedAfterEnd(previouslyAllowed: Boolean, reason: EndReason) =
        previouslyAllowed && permitsAutomaticResume(reason)

    fun isPermanentHttpRejection(status: Int?) =
        status != null && status in 400..499 && status !in setOf(408, 409, 425, 429)

    fun delayMillis(attempt: Int): Long = minOf(30000L, 2000L shl attempt.coerceIn(0, 4))
}

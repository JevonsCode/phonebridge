package dev.phonebridge.phonebridge

import java.security.MessageDigest

/**
 * USB quick connect over an ADB reverse tunnel. Only a computer the owner authorized for USB
 * debugging can reach the DUMP-protected receiver and pairing entry, so ordinary apps cannot
 * inject hints. A hint only selects a loopback route for an already trusted computer; it never
 * grants trust, actions or app access.
 */
object UsbLinkPolicy {
    const val ACTION_LINK = "dev.phonebridge.phonebridge.USB_LINK"
    const val ACTION_PAIR = "dev.phonebridge.phonebridge.USB_PAIR"
    const val PROTOCOL = 1

    fun tokenDigest(token: String): String = MessageDigest.getInstance("SHA-256")
        .digest("phonebridge-usb-v1:$token".toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    fun validDigest(value: String?) = value != null && Regex("[a-f0-9]{64}").matches(value)
    fun validPort(port: Int) = port in 1024..65535
    fun loopbackEndpoint(port: Int): String {
        require(validPort(port)) { "Invalid USB port." }
        return "ws://127.0.0.1:$port/device"
    }
    fun isLoopback(endpoint: String) = endpoint.startsWith("ws://127.0.0.1:")

    /** Result returned to `am broadcast`; the desktop maps it to its own UI state. */
    fun linkState(known: Boolean, resumeAllowed: Boolean, accessibility: Boolean, unlocked: Boolean,
                  connected: Boolean, viaUsb: Boolean, connecting: Boolean): String = when {
        !known -> "unknown"
        !resumeAllowed -> "paused"
        !accessibility -> "accessibility_disabled"
        connected && viaUsb -> "connected_usb"
        connected -> "connected_wireless"
        !unlocked -> "locked"
        connecting -> "connecting"
        else -> "waiting"
    }
}

/** Short-lived, in-memory routes; reboot, unplug or a failed loopback connection forgets them. */
class UsbLinkHints(private val now: () -> Long, private val ttlMillis: Long = 90_000,
                   private val failureCooldownMillis: Long = 300_000) {
    private data class Hint(val port: Int, val at: Long)
    private val hints = mutableMapOf<String, Hint>()
    private val failures = mutableMapOf<String, Long>()

    /** Returns true when this is a new or changed route. A route that just failed is ignored for a while. */
    fun offer(digest: String, port: Int): Boolean {
        require(UsbLinkPolicy.validDigest(digest)) { "Invalid computer digest." }
        require(UsbLinkPolicy.validPort(port)) { "Invalid USB port." }
        failures[digest]?.let { if (now() - it < failureCooldownMillis) return false else failures.remove(digest) }
        val previous = hints[digest]
        hints[digest] = Hint(port, now())
        return previous == null || previous.port != port || expired(previous)
    }

    fun endpointFor(token: String): String? {
        val digest = UsbLinkPolicy.tokenDigest(token)
        val hint = hints[digest] ?: return null
        if (expired(hint)) { hints.remove(digest); return null }
        return UsbLinkPolicy.loopbackEndpoint(hint.port)
    }

    fun active(token: String) = endpointFor(token) != null
    /** The loopback route failed: use the network route and do not retry USB until replugged or cooled down. */
    fun forget(token: String) {
        val digest = UsbLinkPolicy.tokenDigest(token)
        hints.remove(digest); failures[digest] = now()
    }
    /** Cable unplugged: drop every route and failure record so the next plug-in starts fresh. */
    fun clear() { hints.clear(); failures.clear() }
    val size: Int get() = hints.size
    private fun expired(hint: Hint) = now() - hint.at > ttlMillis
}

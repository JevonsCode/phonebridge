package dev.phonebridge.phonebridge

/** A late operation/callback may settle its fence, but cannot end a replacement connection. */
object TransportLifecyclePolicy {
    fun isCurrent(expectedSerial: Long, currentSerial: Long?, expectedSocket: Any?, currentSocket: Any?): Boolean =
        expectedSerial == currentSerial && expectedSocket === currentSocket
}

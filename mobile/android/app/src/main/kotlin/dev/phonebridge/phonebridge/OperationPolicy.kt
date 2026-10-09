package dev.phonebridge.phonebridge

class BridgeFailure(val code: String, override val message: String) : Exception(message)

/** Pure authorization gate, shared by every native RPC including asynchronous capture checks. */
object OperationPolicy {
    fun requireInputFocus(focused: Boolean) {
        if (!focused) {
            throw BridgeFailure("FOCUS_REQUIRED", "Tap the input, request fresh state, then set_text.")
        }
    }

    fun requireNotifications(appEnabled: Boolean, channelImportance: Int?) {
        // Android IMPORTANCE_NONE is 0; a missing channel also cannot expose Stop.
        if (!appEnabled || channelImportance == null || channelImportance <= 0) {
            throw BridgeFailure("NOTIFICATIONS_DISABLED", "Allow PhoneBridge session notifications so Stop is available.")
        }
    }

    fun requireSession(connected: Boolean, generationMatches: Boolean, serviceAttached: Boolean,
                       unlocked: Boolean, actionsEnabled: Boolean, mutation: Boolean) {
        if (!connected || !generationMatches || !serviceAttached) {
            throw BridgeFailure("NO_SESSION", "The session has ended.")
        }
        if (!unlocked) {
            throw BridgeFailure("DEVICE_LOCKED", "Unlock the phone before using PhoneBridge.")
        }
        if (mutation && !actionsEnabled) {
            throw BridgeFailure("READ_ONLY", "Enable actions on the phone.")
        }
    }
}

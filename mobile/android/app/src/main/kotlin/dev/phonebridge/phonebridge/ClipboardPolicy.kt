package dev.phonebridge.phonebridge

import org.json.JSONObject

object ClipboardPolicy {
    // Existing transport boundaries: reserve the maximum command frame for the reply envelope.
    const val RESULT_BUDGET_BYTES = 3 * 1024 * 1024 - 32768

    fun requireEnabled(enabled: Boolean) {
        if (!enabled) throw BridgeFailure("CLIPBOARD_DISABLED", "Clipboard access is disabled in the phone's saved settings.")
    }

    internal fun focusFailure(stage: FocusedOperationFailure): BridgeFailure {
        val message = when (stage) {
            FocusedOperationFailure.NO_FOCUS -> "The temporary clipboard window has no input focus."
            FocusedOperationFailure.FOCUS_TIMEOUT -> "Android did not grant clipboard focus. Retry after the current window settles."
            FocusedOperationFailure.WINDOW_UNAVAILABLE -> "Android could not open the temporary clipboard focus window."
            FocusedOperationFailure.WINDOW_ENDED -> "Clipboard focus ended before reading."
            FocusedOperationFailure.OPERATION_FAILED -> "Android could not read clipboard text."
            FocusedOperationFailure.AUTHORITY_BEFORE -> "Clipboard access changed before reading."
            FocusedOperationFailure.AUTHORITY_AFTER -> "Clipboard access changed before completion."
            FocusedOperationFailure.CLEANUP_FAILED -> "The temporary clipboard focus window could not be removed."
        }
        return BridgeFailure("CLIPBOARD_UNAVAILABLE", message)
    }

    fun result(text: String): JSONObject {
        fun payload(end: Int) = JSONObject().put("text", text.substring(0, end)).put("hasText", text.isNotEmpty())
            .put("truncated", end < text.length).put("totalLength", text.length)
        val complete = payload(text.length)
        if (complete.toString().toByteArray(Charsets.UTF_8).size <= RESULT_BUDGET_BYTES) return complete
        var low = 0; var high = text.length
        while (low < high) {
            val middle = low + (high - low + 1) / 2
            if (payload(middle).toString().toByteArray(Charsets.UTF_8).size <= RESULT_BUDGET_BYTES) low = middle
            else high = middle - 1
        }
        if (low > 0 && low < text.length && Character.isHighSurrogate(text[low - 1]) && Character.isLowSurrogate(text[low])) low--
        return payload(low)
    }
}

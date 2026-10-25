package dev.phonebridge.phonebridge

import android.content.ClipboardManager
import org.json.JSONObject

/** Clipboard authorization remains in the caller's saved-switch and session validation. */
internal object ClipboardBridge {
    fun read(owner: PhoneAccessibilityService, validate: () -> Unit, complete: (JSONObject?, BridgeFailure?) -> Unit) {
        AccessibilityFocusedOperation.run(owner, validate, ClipboardPolicy::focusFailure, {
            val clip = owner.getSystemService(ClipboardManager::class.java).primaryClip
            val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() ?: "" else ""
            ClipboardPolicy.result(text)
        }, complete)
    }

    fun cancel(owner: PhoneAccessibilityService) = AccessibilityFocusedOperation.cancel(owner)
}

@file:Suppress("DEPRECATION")

package dev.phonebridge.phonebridge

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.UUID

/** Android 10+ clipboard reads require actual input focus. No clipboard data enters an Intent. */
internal object ClipboardBridge {
    const val TOKEN = "phonebridgeClipboardRequest"
    private class Request(val token: String, val owner: PhoneAccessibilityService, val validate: () -> Unit,
                          val complete: (JSONObject?, BridgeFailure?) -> Unit) {
        var activity: WeakReference<ClipboardBridgeActivity>? = null
        var result: JSONObject? = null
        var error: BridgeFailure? = null
        var read = false
        var timeout: Runnable? = null
    }
    private var pending: Request? = null

    fun read(owner: PhoneAccessibilityService, validate: () -> Unit, complete: (JSONObject?, BridgeFailure?) -> Unit) {
        if (pending != null) throw BridgeFailure("BUSY", "A clipboard read is already settling.")
        validate()
        val request = Request(UUID.randomUUID().toString(), owner, validate, complete)
        pending = request
        request.timeout = Runnable {
            if (pending !== request) return@Runnable
            request.activity?.get()?.finishAndRemoveTask()
            settle(request, BridgeFailure("CLIPBOARD_UNAVAILABLE", "Android did not grant clipboard focus. Retry after the current window settles."))
        }.also { BridgeSession.main.postDelayed(it, 5000) }
        try {
            owner.startActivity(Intent(owner, ClipboardBridgeActivity::class.java).putExtra(TOKEN, request.token)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or Intent.FLAG_ACTIVITY_NO_ANIMATION))
        } catch (_: Exception) {
            settle(request, BridgeFailure("CLIPBOARD_UNAVAILABLE", "Android could not open the temporary clipboard focus window."))
        }
    }

    fun attach(activity: ClipboardBridgeActivity, token: String?): Boolean {
        val request = pending?.takeIf { it.token == token } ?: return false
        request.activity = WeakReference(activity)
        return true
    }

    fun focused(activity: ClipboardBridgeActivity, token: String?) {
        val request = pending?.takeIf { it.token == token && it.activity?.get() === activity } ?: run {
            activity.finishAndRemoveTask(); return
        }
        if (request.read) return
        request.read = true
        try {
            request.validate()
            if (!activity.hasWindowFocus()) throw BridgeFailure("CLIPBOARD_UNAVAILABLE", "The temporary clipboard window has no input focus.")
            val clip = activity.getSystemService(ClipboardManager::class.java).primaryClip
            val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() ?: "" else ""
            request.result = ClipboardPolicy.result(text)
        } catch (error: BridgeFailure) {
            request.error = error
        } catch (_: Exception) {
            request.error = BridgeFailure("CLIPBOARD_UNAVAILABLE", "Android could not read clipboard text.")
        }
        activity.finishAndRemoveTask()
    }

    fun destroyed(activity: ClipboardBridgeActivity, token: String?) {
        val request = pending?.takeIf { it.token == token && it.activity?.get() === activity } ?: return
        settle(request, request.error ?: if (!request.read) BridgeFailure("CLIPBOARD_UNAVAILABLE", "Clipboard focus ended before reading.") else null)
    }

    fun cancel(owner: PhoneAccessibilityService) {
        val request = pending?.takeIf { it.owner === owner } ?: return
        request.activity?.get()?.finishAndRemoveTask()
        settle(request, BridgeFailure("NO_SESSION", "The phone service ended during clipboard access."))
    }

    private fun settle(request: Request, failure: BridgeFailure?) {
        if (pending !== request) return
        pending = null
        request.timeout?.let { BridgeSession.main.removeCallbacks(it) }
        var error = failure
        if (error == null) {
            try { request.validate() } catch (changed: BridgeFailure) { error = changed }
            catch (_: Exception) { error = BridgeFailure("CLIPBOARD_UNAVAILABLE", "Clipboard access changed before completion.") }
        }
        val result = request.result
        request.result = null
        request.activity = null
        request.complete(if (error == null) result else null, error)
    }
}

/** Focusable, transparent, noninteractive, separate task; finishing restores the previous app. */
class ClipboardBridgeActivity : Activity() {
    private var token: String? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        token = intent.getStringExtra(ClipboardBridge.TOKEN)
        if (!ClipboardBridge.attach(this, token)) { finishAndRemoveTask(); return }
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_SECURE)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_UNCHANGED or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        setContentView(View(this).apply { setBackgroundColor(Color.TRANSPARENT); isFocusableInTouchMode = true; requestFocus() })
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) window.decorView.post { ClipboardBridge.focused(this, token) }
    }

    override fun onDestroy() {
        super.onDestroy()
        ClipboardBridge.destroyed(this, token)
    }
}

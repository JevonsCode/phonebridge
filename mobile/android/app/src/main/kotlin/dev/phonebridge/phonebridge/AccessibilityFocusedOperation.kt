package dev.phonebridge.phonebridge

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/** A temporary window under existing accessibility authorization; never launches a helper Activity. */
internal object AccessibilityFocusedOperation {
    private class FocusWindow(owner: PhoneAccessibilityService, val focused: () -> Unit, val detached: () -> Unit) : View(owner) {
        private var drawn = false
        val ready: Boolean get() = drawn && isAttachedToWindow && isShown && hasWindowFocus()

        init {
            setBackgroundColor(Color.TRANSPARENT)
            setWillNotDraw(false)
            isFocusableInTouchMode = true
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (!drawn) {
                drawn = true
                notifyFocused()
            }
        }

        override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
            super.onWindowFocusChanged(hasWindowFocus)
            if (hasWindowFocus) notifyFocused()
        }

        private fun notifyFocused() {
            // Finish the drawing/focus traversal before dispatching under this visible window.
            if (ready) BridgeSession.main.post { if (ready) focused() }
        }

        override fun onDetachedFromWindow() {
            drawn = false
            super.onDetachedFromWindow()
            detached()
        }
    }

    private class Request<T : Any>(val owner: PhoneAccessibilityService, val validate: () -> Unit,
                                  val failure: (FocusedOperationFailure) -> BridgeFailure, operation: () -> T,
                                  val complete: (T?, BridgeFailure?) -> Unit) {
        val manager = owner.getSystemService(WindowManager::class.java)
        var view: FocusWindow? = null
        var delivered = false
        val lifecycle: FocusedOperationLifecycle<T> = FocusedOperationLifecycle(validate, {
            if (view?.ready != true) throw failure(FocusedOperationFailure.NO_FOCUS)
            operation()
        }, ::releaseWindow, failure) { result, error -> finish(this, result, error) }
        val timeout = Runnable { lifecycle.fail(failure(FocusedOperationFailure.FOCUS_TIMEOUT)) }
        val guard = object : Runnable {
            override fun run() {
                if (pending !== this@Request) return
                if (!lifecycle.finished) lifecycle.checkAuthority()
                else if (lifecycle.cleanupPending) lifecycle.retryCleanup()
                if (delivered && lifecycle.finished && !lifecycle.cleanupPending) pending = null
                else BridgeSession.main.postDelayed(this, if (lifecycle.finished) 250 else 100)
            }
        }

        fun releaseWindow(): Boolean {
            val target = view ?: return true
            var removed = false
            try {
                manager.removeViewImmediate(target)
                removed = true
            } catch (_: IllegalArgumentException) {
                // WindowManager no longer owns this exact View (including a failed add).
                removed = !target.isAttachedToWindow
            } catch (_: Exception) { /* Keep ownership and retry; never drop an attached window. */ }
            if (removed && !target.isAttachedToWindow) {
                view = null
                return true
            }
            // Release focus even if an OEM delays removal. Only our own View is changed.
            try {
                target.clearFocus()
                target.visibility = View.GONE
            } catch (_: Exception) { /* Still attempt to mark our own window unfocusable. */ }
            try {
                val params = target.layoutParams as? WindowManager.LayoutParams
                if (params != null) {
                    params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    manager.updateViewLayout(target, params)
                }
            } catch (_: Exception) { /* The guard retains and retries the same View. */ }
            return false
        }
    }

    private var pending: Request<*>? = null

    fun <T : Any> run(owner: PhoneAccessibilityService, validate: () -> Unit,
                      failure: (FocusedOperationFailure) -> BridgeFailure, operation: () -> T,
                      complete: (T?, BridgeFailure?) -> Unit) {
        if (pending != null) throw BridgeFailure("BUSY", "A focused operation is already settling.")
        validate()
        val request = Request(owner, validate, failure, operation, complete)
        pending = request
        BridgeSession.main.postDelayed(request.timeout, 5000)
        BridgeSession.main.postDelayed(request.guard, 100)
        try {
            val target = FocusWindow(owner, {
                if (pending === request) request.lifecycle.focused(request.view?.ready == true)
            }, {
                request.lifecycle.fail(failure(FocusedOperationFailure.WINDOW_ENDED))
            })
            request.view = target
            val params = WindowManager.LayoutParams(
                1, 1, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM or WindowManager.LayoutParams.FLAG_SECURE,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_UNCHANGED or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
                title = "PhoneBridge operation focus"
            }
            // Real focus satisfies ClipboardService; a drawn non-app window supplies
            // Android's existing visible-window background-launch exemption.
            // ALT_FOCUSABLE_IM keeps this non-editor window from becoming an IME target.
            request.manager.addView(target, params)
            target.requestFocus()
        } catch (_: Exception) {
            request.lifecycle.fail(failure(FocusedOperationFailure.WINDOW_UNAVAILABLE))
        }
    }

    fun cancel(owner: PhoneAccessibilityService) {
        val request = pending?.takeIf { it.owner === owner } ?: return
        if (!request.lifecycle.finished) request.lifecycle.fail(BridgeFailure("NO_SESSION", "The phone service ended during a focused operation."))
        else request.lifecycle.retryCleanup()
    }

    private fun <T : Any> finish(request: Request<T>, result: T?, failure: BridgeFailure?) {
        BridgeSession.main.removeCallbacks(request.timeout)
        // Never return success while our window remains owned. Removing our exact
        // View releases temporary focus without launching a helper task.
        BridgeSession.main.post {
            if (request.delivered) return@post
            request.delivered = true
            var error = failure
            if (error == null) {
                try { request.validate() }
                catch (changed: BridgeFailure) { error = changed }
                catch (_: Exception) { error = request.failure(FocusedOperationFailure.AUTHORITY_AFTER) }
            }
            if (!request.lifecycle.cleanupPending && pending === request) {
                pending = null
                BridgeSession.main.removeCallbacks(request.guard)
            }
            request.complete(if (error == null) result else null, error)
        }
    }
}

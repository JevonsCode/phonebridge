@file:Suppress("DEPRECATION")

package dev.phonebridge.phonebridge

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.os.SystemClock
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/** Physical display pixels, shared by dispatchGesture and the drawing model. */
internal data class TrailMotion(val method: String, val x1: Float, val y1: Float,
                                val x2: Float, val y2: Float, val durationMs: Long) {
    val lifetimeMs: Long get() = if (method == "tap") 450 else durationMs + 350
    fun frame(elapsedMs: Long, originX: Int, originY: Int): TrailFrame {
        val elapsed = elapsedMs.coerceIn(0, lifetimeMs)
        val progress = if (method == "swipe") (elapsed.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
        val fadeStart = if (method == "tap") 0 else durationMs
        val alpha = (1f - (elapsed - fadeStart).coerceAtLeast(0).toFloat() /
            (lifetimeMs - fadeStart)).coerceIn(0f, 1f)
        return TrailFrame(x1 - originX, y1 - originY,
            x1 + (x2 - x1) * progress - originX,
            y1 + (y2 - y1) * progress - originY, alpha,
            if (method == "tap") elapsed.toFloat() / lifetimeMs else 0f)
    }
}

internal data class TrailFrame(val startX: Float, val startY: Float, val x: Float,
                              val y: Float, val alpha: Float, val ripple: Float)

internal object TrailSettlement {
    const val MAX_MS = 250L
    fun ready(frames: Int, ownedWindowVisible: Boolean, elapsedMs: Long,
              quietMs: Long = 0, requiredQuietMs: Long = 0) =
        elapsedMs >= MAX_MS || (frames >= 2 && !ownedWindowVisible &&
            elapsedMs >= requiredQuietMs && quietMs >= requiredQuietMs)
}

/** Small, temporary ownership metadata only: no gesture coordinates or touch history.
 * Android can deliver an overlay window-state event after the View was removed.
 * Its creation timestamp must fall inside that exact owned window's lifetime;
 * a later foreign window reusing the same id never inherits ownership. */
internal class OwnedTrailWindows {
    private data class Lifetime(val id: Int, val openedAtMs: Long, var closedAtMs: Long? = null)
    private val lifetimes = ArrayDeque<Lifetime>()
    fun remember(id: Int, openedAtMs: Long, nowMs: Long) {
        prune(nowMs)
        if (id < 0 || lifetimes.any { it.id == id && it.openedAtMs == openedAtMs }) return
        lifetimes.addLast(Lifetime(id, openedAtMs))
        while (lifetimes.size > MAX_WINDOWS) lifetimes.removeFirst()
    }
    fun retire(openedAtMs: Long, closedAtMs: Long) {
        lifetimes.filter { it.openedAtMs == openedAtMs && it.closedAtMs == null }
            .forEach { it.closedAtMs = closedAtMs }
        prune(closedAtMs)
    }
    fun ownsEvent(type: Int, id: Int, eventTimeMs: Long, nowMs: Long): Boolean {
        prune(nowMs)
        if (type != AccessibilityEvent.TYPE_WINDOWS_CHANGED &&
            type != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return false
        return id >= 0 && lifetimes.any { it.id == id && eventTimeMs >= it.openedAtMs &&
            eventTimeMs <= (it.closedAtMs ?: nowMs) }
    }
    private fun prune(nowMs: Long) {
        lifetimes.removeAll { it.closedAtMs?.let { end -> nowMs - end > RETAIN_MS } == true }
    }
    companion object {
        const val MAX_WINDOWS = 32
        const val RETAIN_MS = 5000L
    }
}

/** SharedPreferences.commit can update memory even when its disk write fails.
 * Keep the prior effective value until a later successful save, and restore the
 * stored value best-effort so the same process and a subsequent launch agree. */
internal class TrailPreferencePersistence {
    private var restoredValue: Boolean? = null
    fun read(readStored: () -> Boolean): Boolean = restoredValue ?: readStored()
    fun save(enabled: Boolean, readStored: () -> Boolean, writeStored: (Boolean) -> Boolean) {
        val previous = read(readStored)
        try {
            if (!writeStored(enabled)) throw IllegalStateException("Could not save operation trail preference.")
            restoredValue = null
        } catch (error: Exception) {
            restoredValue = previous
            try { writeStored(previous) } catch (_: Exception) { /* Effective value remains restored. */ }
            throw error
        }
    }
}

/** Own preference file: never shares pairing, authorization, or language state. */
internal object OperationTrailPreference {
    private const val FILE = "phonebridge_operation_trails"
    private const val KEY = "showOperationTrails"
    private val persistence = TrailPreferencePersistence()
    fun enabled(context: Context) = persistence.read {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getBoolean(KEY, true)
    }
    fun save(context: Context, enabled: Boolean) {
        val preferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        persistence.save(enabled, { preferences.getBoolean(KEY, true) }) { value ->
            preferences.edit().putBoolean(KEY, value).commit()
        }
    }
}

/** Main-thread only. Cosmetic failures cannot change dispatch or replay an action. */
internal class OperationTrail(private val service: PhoneAccessibilityService) {
    private val manager = service.getSystemService(WindowManager::class.java)
    private var view: TrailView? = null
    private var animation: Choreographer.FrameCallback? = null
    private var expiry: Runnable? = null
    private var removalPending = false
    private val ownedWindowIds = linkedSetOf<Int>()
    private val ownedWindows = OwnedTrailWindows()
    private var openedAtMs = 0L
    private var lastOwnedEventMs = 0L

    fun ownsEvent(event: AccessibilityEvent?): Boolean {
        val now = SystemClock.uptimeMillis()
        val owned = event != null && ownedWindows.ownsEvent(event.eventType,
            event.windowId, event.eventTime, now)
        if (owned) lastOwnedEventMs = SystemClock.uptimeMillis()
        return owned
    }

    private fun rememberWindow(target: View) {
        val node = target.createAccessibilityNodeInfo() ?: return
        val id = try { node.windowId } finally { node.recycle() }
        if (id >= 0) {
            ownedWindowIds.add(id)
            ownedWindows.remember(id, openedAtMs, SystemClock.uptimeMillis())
        }
    }

    fun show(motion: TrailMotion) {
        try {
            if (!OperationTrailPreference.enabled(service)) return
            clear()
            if (view != null) return
            val target = TrailView(service, motion) { failed -> if (view === failed) clear() }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT).apply {
                gravity = Gravity.TOP or Gravity.LEFT
                setFitInsetsTypes(0)
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                title = "PhoneBridge operation trail"
            }
            view = target
            openedAtMs = SystemClock.uptimeMillis()
            manager.addView(target, params)
            rememberWindow(target)
            target.post { if (view === target) rememberWindow(target) }
            val started = SystemClock.uptimeMillis()
            val choreographer = Choreographer.getInstance()
            lateinit var frame: Choreographer.FrameCallback
            frame = Choreographer.FrameCallback {
                if (view === target && animation === frame) {
                    target.elapsedMs = SystemClock.uptimeMillis() - started
                    if (target.elapsedMs >= motion.lifetimeMs) clear()
                    else { target.invalidate(); choreographer.postFrameCallback(frame) }
                }
            }
            animation = frame
            choreographer.postFrameCallback(frame)
            expiry = Runnable { if (view === target) clear() }.also {
                BridgeSession.main.postDelayed(it, motion.lifetimeMs)
            }
        } catch (_: Exception) { clear() }
    }

    fun clear() {
        expiry?.let { BridgeSession.main.removeCallbacks(it) }
        expiry = null
        animation?.let { Choreographer.getInstance().removeFrameCallback(it) }
        animation = null
        val target = view ?: return
        try { rememberWindow(target) } catch (_: Exception) { /* Best-effort identity discovery. */ }
        removalPending = true
        try {
            manager.removeViewImmediate(target)
            ownedWindows.retire(openedAtMs, SystemClock.uptimeMillis())
            view = null
        } catch (_: Exception) {
            // Keep exact ownership for a later cleanup attempt; never remove a foreign window.
            if (!target.isAttachedToWindow) {
                ownedWindows.retire(openedAtMs, SystemClock.uptimeMillis())
                view = null
            }
        }
    }

    /** Remove our exact View, allow compositor frames and the service's notification
     * debounce interval to drain main-thread events.
     * Recheck its window id until absent, bounded to 250 ms; windowScope still rejects
     * every remaining accessibility overlay, including ours if removal failed. */
    fun beforeRpc(ready: () -> Unit) {
        clear()
        if (!removalPending) { ready(); return }
        val started = SystemClock.uptimeMillis()
        val requiredQuiet = service.serviceInfo.notificationTimeout.coerceIn(0, TrailSettlement.MAX_MS)
        var frames = 0
        var finished = false
        val choreographer = Choreographer.getInstance()
        lateinit var frame: Choreographer.FrameCallback
        lateinit var deadline: Runnable
        fun finish(stillVisible: Boolean) {
            if (finished) return
            finished = true
            choreographer.removeFrameCallback(frame)
            BridgeSession.main.removeCallbacks(deadline)
            BridgeSession.main.post {
                removalPending = view != null || stillVisible
                if (!removalPending) ownedWindowIds.clear()
                ready()
            }
        }
        frame = Choreographer.FrameCallback {
            frames++
            val stillVisible = try { service.windows.let { windows ->
                try { windows.any { it.id in ownedWindowIds } }
                finally { windows.forEach { it.recycle() } }
            } } catch (_: Exception) { true }
            val now = SystemClock.uptimeMillis()
            if (TrailSettlement.ready(frames, stillVisible, now - started,
                now - lastOwnedEventMs, requiredQuiet)) {
                finish(stillVisible)
            } else choreographer.postFrameCallback(frame)
        }
        deadline = Runnable { finish(true) }
        BridgeSession.main.postDelayed(deadline, TrailSettlement.MAX_MS)
        choreographer.postFrameCallback(frame)
    }

    private class TrailView(context: Context, private val motion: TrailMotion,
                            private val drawFailure: (TrailView) -> Unit) : View(context) {
        var elapsedMs = 0L
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(63, 131, 248)
            strokeCap = Paint.Cap.ROUND
        }
        private val origin = IntArray(2)
        private val density = resources.displayMetrics.density
        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            isFocusable = false
            isClickable = false
        }
        override fun onDraw(canvas: Canvas) {
            try { drawTrail(canvas) } catch (_: Exception) { post { drawFailure(this) } }
        }
        private fun drawTrail(canvas: Canvas) {
            // Use the actual WM origin, so inset and landscape layouts cannot shift pixels.
            getLocationOnScreen(origin)
            val frame = motion.frame(elapsedMs, origin[0], origin[1])
            paint.alpha = (frame.alpha * 210).toInt()
            if (motion.method == "swipe") {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2.5f * density
                canvas.drawLine(frame.startX, frame.startY, frame.x, frame.y, paint)
            }
            paint.style = Paint.Style.FILL
            canvas.drawCircle(frame.x, frame.y, 5f * density, paint)
            if (motion.method == "tap") {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.5f * density
                canvas.drawCircle(frame.x, frame.y, (8f + 15f * frame.ripple) * density, paint)
            }
        }
    }
}

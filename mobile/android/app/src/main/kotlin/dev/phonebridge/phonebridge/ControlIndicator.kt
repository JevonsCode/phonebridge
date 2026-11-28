package dev.phonebridge.phonebridge

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager

/** Height of the visible edge in dp; it always stays inside the status bar inset. */
internal object ControlIndicatorPolicy {
    const val HEIGHT_DP = 4f
    /** Never taller than the status bar, so it stays outside screenshot crops and gesture bounds. */
    fun heightPx(density: Float, statusBarPx: Int): Int =
        if (statusBarPx <= 0) 0 else minOf(statusBarPx, (HEIGHT_DP * density).toInt().coerceAtLeast(2))
}

/**
 * A thin, non-touchable line across the top edge while an AI task holds control, so the owner
 * can see the phone is being operated even when the notification shade is closed. It lives in
 * the status-bar inset: screenshots crop it out and injected gestures pass through it.
 */
internal class ControlIndicator(private val service: PhoneAccessibilityService) {
    private val manager = service.getSystemService(WindowManager::class.java)
    private var view: View? = null
    private val windowIds = mutableSetOf<Int>()

    fun owns(windowId: Int) = windowId >= 0 && windowId in windowIds

    fun update(visible: Boolean) {
        if (visible && AutomationPreferences.showControlIndicator(service)) show() else hide()
    }

    private fun show() {
        if (view != null) return
        try {
            val statusBar = manager.maximumWindowMetrics.windowInsets
                .getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top
            val height = ControlIndicatorPolicy.heightPx(service.resources.displayMetrics.density, statusBar)
            if (height == 0) return
            val target = EdgeView(service)
            val params = WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, height,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT).apply {
                gravity = Gravity.TOP or Gravity.LEFT
                setFitInsetsTypes(0)
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                title = "PhoneBridge control indicator"
            }
            view = target
            manager.addView(target, params)
            remember(target)
            target.post { if (view === target) remember(target) }
        } catch (_: Exception) { hide() }
    }

    private fun remember(target: View) {
        val node = target.createAccessibilityNodeInfo() ?: return
        try { if (node.windowId >= 0) windowIds.add(node.windowId) } finally { node.recycle() }
    }

    fun hide() {
        val target = view ?: return
        view = null
        try { manager.removeViewImmediate(target) } catch (_: Exception) { }
        // Keep the ids briefly: Android may still list the closing window in the next scan.
        BridgeSession.main.postDelayed({ if (view == null) windowIds.clear() }, 2000)
    }

    private class EdgeView(context: android.content.Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            isFocusable = false
            isClickable = false
        }
        override fun onDraw(canvas: Canvas) {
            paint.color = Color.rgb(63, 131, 248)
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        }
    }
}

package dev.phonebridge.phonebridge

import android.view.accessibility.AccessibilityEvent

/** Main-thread input arbitration. Only event type, package and monotonic time are used. */
class LocalPhoneUse(private val uptime: () -> Long, private val quietMillis: Long = 10_000) {
    companion object {
        fun requireFreshTarget(method: String) {
            if (method in setOf("tap", "long_press", "swipe", "node_action", "commit_text", "set_text", "global_action"))
                throw BridgeFailure("OBSERVATION_REQUIRED", "Local input changed the screen. Request fresh state or a screenshot before acting.")
        }
    }
    enum class Touch { ACTIVITY, ACCESSIBILITY }
    private val held = mutableSetOf<Touch>()
    private var quietUntil = 0L
    val active: Boolean get() = held.isNotEmpty() || uptime() < quietUntil

    fun activity() { quietUntil = uptime() + quietMillis }
    fun begin(source: Touch) { held.add(source); activity() }
    fun end(source: Touch) { if (held.remove(source)) activity() }

    // App-generated accessibility events have no input origin. Ignore the expected app's
    // feedback around an actual native dispatch, including delayed delivery after completion.
    private data class Effect(val packageName: String, val start: Long, var end: Long, var touchUntil: Long,
        var eventTypes: Int)
    private val effects = ArrayDeque<Effect>()
    private var gesture: Effect? = null

    fun expectFeedback(packageName: String, isGesture: Boolean = false, eventTypes: Int, start: Long = uptime()) {
        val now = uptime()
        effects.removeAll { it.end < now - 1000 }
        if (effects.size == 32) effects.removeFirst()
        val touchEvents = AccessibilityEvent.TYPE_TOUCH_INTERACTION_START or AccessibilityEvent.TYPE_TOUCH_INTERACTION_END
        val effect = Effect(packageName, start, if (isGesture) Long.MAX_VALUE else now + 500,
            if (isGesture) Long.MAX_VALUE else -1, if (isGesture) eventTypes or touchEvents else eventTypes)
        effects.addLast(effect)
        if (isGesture) gesture = effect
    }

    fun endRemoteGesture() {
        gesture?.let {
            it.touchUntil = uptime()
            it.end = it.touchUntil + 500
        }
        gesture = null
    }

    fun accessibilityEvent(type: Int, packageName: String?, eventTime: Long): Boolean {
        when (type) {
            AccessibilityEvent.TYPE_TOUCH_INTERACTION_START,
            AccessibilityEvent.TYPE_TOUCH_INTERACTION_END -> {
                val source = Touch.ACCESSIBILITY
                if (type == AccessibilityEvent.TYPE_TOUCH_INTERACTION_END && source in held) end(source)
                else if (consumeFeedback(type, null, eventTime, touch = true)) return false
                else if (type == AccessibilityEvent.TYPE_TOUCH_INTERACTION_START) begin(source)
                else activity() // Android may attach mid-gesture.
            }
            AccessibilityEvent.TYPE_VIEW_CLICKED, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED,
            AccessibilityEvent.TYPE_VIEW_CONTEXT_CLICKED, AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                if (consumeFeedback(type, packageName, eventTime, touch = false)) return false
                activity()
            }
            else -> return false
        }
        return true
    }

    private fun consumeFeedback(type: Int, packageName: String?, time: Long, touch: Boolean): Boolean {
        val effect = effects.firstOrNull {
            (it.eventTypes and type) != 0 && time >= it.start &&
                (if (touch) time <= it.touchUntil else it.packageName == packageName && time <= it.end)
        } ?: return false
        // One injection may produce many scroll/text updates, but only one click, start or end
        // of a given type. A second click/interaction inside the short feedback window is local.
        if (type != AccessibilityEvent.TYPE_VIEW_SCROLLED && type != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED)
            effect.eventTypes = effect.eventTypes and type.inv()
        return true
    }
}

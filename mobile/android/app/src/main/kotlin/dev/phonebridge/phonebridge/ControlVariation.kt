package dev.phonebridge.phonebridge

import kotlin.random.Random

internal object ControlVariation {
    val mutations = setOf("tap", "long_press", "swipe", "set_text", "node_action", "commit_text",
        "global_action", "launch_app", "set_clipboard")

    fun delayMillis(random: Random = Random.Default): Long = random.nextLong(300, 1301)

    /** Integer offsets in physical pixels. The caller validates the original point first. */
    fun tap(center: Pair<Float, Float>, random: Random = Random.Default,
            allowed: (Float, Float) -> Boolean): Pair<Float, Float> {
        repeat(64) {
            val dx = random.nextInt(-10, 11)
            val dy = random.nextInt(-10, 11)
            if (dx * dx + dy * dy <= 100) {
                val x = center.first + dx
                val y = center.second + dy
                if (allowed(x, y)) return Pair(x, y)
            }
        }
        return center
    }
}

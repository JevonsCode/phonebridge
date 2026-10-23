package dev.phonebridge.phonebridge

import android.content.Context
import android.os.Handler
import android.os.PowerManager

object ScreenAwakePolicy {
    val modes = setOf("off", "controlling", "always")
    fun shouldHold(mode: String, serviceAvailable: Boolean, controlling: Boolean, interactive: Boolean) =
        serviceAvailable && interactive && (mode == "always" || mode == "controlling" && controlling)
}

/** A display lock keeps other apps visible; it cannot wake a manually locked display. */
class ScreenAwakeController(context: Context, private val main: Handler) {
    private val preferences = context.getSharedPreferences("screen_awake", Context.MODE_PRIVATE)
    private val power = context.getSystemService(PowerManager::class.java)
    @Suppress("DEPRECATION")
    private val lock = power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK, "PhoneBridge:display").apply { setReferenceCounted(false) }
    var mode: String = preferences.getString("mode", "controlling").takeIf { it in ScreenAwakePolicy.modes } ?: "controlling"
        private set
    val held: Boolean get() = lock.isHeld
    private var available = false
    private var controlling = false
    private val renew = object : Runnable {
        override fun run() { update(available, controlling) }
    }
    fun select(value: String) {
        require(value in ScreenAwakePolicy.modes) { "Unknown screen awake mode." }
        check(preferences.edit().putString("mode", value).commit()) { "Could not save screen awake mode." }
        mode = value
        update(available, controlling)
    }
    fun update(serviceAvailable: Boolean, hasControl: Boolean) {
        available = serviceAvailable
        controlling = hasControl
        main.removeCallbacks(renew)
        if (ScreenAwakePolicy.shouldHold(mode, available, controlling, power.isInteractive)) {
            // Bounded even if the process stops running; no ACQUIRE_CAUSES_WAKEUP or ON_AFTER_RELEASE.
            lock.acquire(45_000)
        } else if (lock.isHeld) lock.release()
        if (available && mode != "off") main.postDelayed(renew, 15_000)
    }
}

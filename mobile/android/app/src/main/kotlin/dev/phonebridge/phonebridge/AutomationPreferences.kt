package dev.phonebridge.phonebridge

import android.content.Context

internal object AutomationPreferenceDefaults {
    fun value(key: String): Boolean = key != "protectConnectionControls"
}

internal class AutomationPreferenceState {
    private val restored = mutableMapOf<String, Boolean>()
    fun read(key: String, stored: () -> Boolean): Boolean = restored[key] ?: stored()
    fun save(key: String, value: Boolean, stored: () -> Boolean, write: (Boolean) -> Boolean) {
        val previous = read(key, stored)
        try {
            check(write(value)) { "Could not save automation preference." }
            restored.remove(key)
        } catch (error: Exception) {
            restored[key] = previous
            runCatching { write(previous) }
            throw error
        }
    }
}

/** Global owner preferences. These never grant a computer a connection or control lease. */
object AutomationPreferences {
    private val state = AutomationPreferenceState()
    private fun preferences(context: Context) = context.getSharedPreferences("phonebridge_automation", Context.MODE_PRIVATE)
    private fun read(context: Context, key: String) = state.read(key) { preferences(context).getBoolean(key, AutomationPreferenceDefaults.value(key)) }
    private fun save(context: Context, key: String, value: Boolean) {
        val preferences = preferences(context)
        state.save(key, value, { preferences.getBoolean(key, AutomationPreferenceDefaults.value(key)) }) { preferences.edit().putBoolean(key, it).commit() }
    }
    fun clipboardAccessEnabled(context: Context): Boolean = read(context, "clipboardAccessEnabled")
    fun setClipboardAccessEnabled(context: Context, enabled: Boolean) = save(context, "clipboardAccessEnabled", enabled)
    fun protectConnectionControls(context: Context): Boolean = read(context, "protectConnectionControls")
    fun setProtectConnectionControls(context: Context, enabled: Boolean) = save(context, "protectConnectionControls", enabled)
}

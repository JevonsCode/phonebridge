package dev.phonebridge.phonebridge

import android.content.ComponentName
import android.content.Context
import android.provider.Settings

/** A missing service instance during process startup is not a revoked grant. */
object AccessibilityStatus {
    fun authorized(context: Context): Boolean {
        val expected = ComponentName(context, PhoneAccessibilityService::class.java)
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        return enabled.orEmpty().split(':').any { ComponentName.unflattenFromString(it) == expected }
    }

    fun state(authorized: Boolean, ready: Boolean) = when {
        ready -> "ready"
        authorized -> "reconnecting"
        else -> "disabled"
    }
}

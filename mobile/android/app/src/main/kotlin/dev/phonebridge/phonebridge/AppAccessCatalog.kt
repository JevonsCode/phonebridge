package dev.phonebridge.phonebridge

import android.content.Context
import android.content.Intent
import android.provider.Settings
import java.text.Collator

/** Only launcher apps are enumerated; existing grants remain visible even after uninstall. */
object AppAccessCatalog {
    fun protectedPackages(context: Context): Set<String> {
        val fixed = setOf("android", "com.android.systemui", "com.android.settings",
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
            "com.android.packageinstaller", "com.google.android.packageinstaller")
        return fixed + listOf(Settings.ACTION_ACCESSIBILITY_SETTINGS, Settings.ACTION_SETTINGS,
            "android.intent.action.MANAGE_PERMISSIONS").mapNotNull {
            context.packageManager.resolveActivity(Intent(it), 0)?.activityInfo?.packageName
        }
    }

    fun list(context: Context, allowed: List<String>): List<Map<String, Any>> {
        val pm = context.packageManager
        val protected = protectedPackages(context)
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .associate { it.activityInfo.packageName to it.loadLabel(pm).toString() }
        val collator = Collator.getInstance()
        return (apps.keys + allowed).map { packageName ->
            mapOf<String, Any>("packageName" to packageName, "name" to (apps[packageName] ?: packageName),
                "installed" to apps.containsKey(packageName), "protected" to (packageName in protected))
        }.sortedWith { a, b -> collator.compare(a["name"] as String, b["name"] as String) }
    }
}

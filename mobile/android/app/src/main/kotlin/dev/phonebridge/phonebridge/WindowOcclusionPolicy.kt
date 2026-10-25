package dev.phonebridge.phonebridge

object WindowOcclusionPolicy {
    fun isNonInteractiveToast(type: Int, focused: Boolean, active: Boolean, rootClass: String?, title: String?, interactive: Boolean): Boolean =
        type == 3 && !focused && !active && !interactive && (rootClass == "android.widget.Toast" || title == "Toast")

    fun details(foregroundPackage: String, type: Int, owner: String?, toast: Boolean = false): Map<String, Any> {
        val reason = when {
            toast -> "toast"
            type == 2 -> "keyboard"
            type == 4 -> "accessibility_overlay"
            type == 1 -> "other_application"
            else -> "system_dialog"
        }
        return mutableMapOf<String, Any>("foregroundPackage" to foregroundPackage, "obscuredBy" to reason,
            "windowType" to type).apply { if (owner != null) put("obscuringPackage", owner) }
    }
}

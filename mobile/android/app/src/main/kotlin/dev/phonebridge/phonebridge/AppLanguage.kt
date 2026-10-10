package dev.phonebridge.phonebridge

import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import java.util.Locale

/** Separate from encrypted pairing and authorization; never recreates the Activity. */
object AppLanguage {
    private const val FILE = "phonebridge_language"
    fun preference(context: Context): String =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString("language", "system")
            ?.takeIf { it in setOf("system", "zh", "en") } ?: "system"

    fun select(context: Context, language: String) {
        require(language in setOf("system", "zh", "en")) { "Invalid language preference." }
        check(context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putString("language", language).commit()) { "Could not save language preference." }
    }

    fun resources(context: Context): android.content.res.Resources {
        val preference = preference(context)
        val system = context.resources.configuration.locales[0].language
        val language = if (preference == "system") (if (system == "zh") "zh" else "en") else preference
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(LocaleList(Locale.forLanguageTag(language)))
        return context.createConfigurationContext(configuration).resources
    }
}

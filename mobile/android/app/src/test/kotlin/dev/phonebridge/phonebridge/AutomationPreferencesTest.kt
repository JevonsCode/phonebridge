package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class AutomationPreferencesTest {
    @Test fun optionalConnectionProtectionDefaultsOffWhileAutomationCapabilitiesStayOn() {
        assertFalse(AutomationPreferenceDefaults.value("protectConnectionControls"))
        assertTrue(AutomationPreferenceDefaults.value("clipboardAccessEnabled"))
        assertTrue(AutomationPreferenceDefaults.value("autoReceiveFilesEnabled"))
        assertTrue(AutomationPreferenceDefaults.value("saveMediaToGallery"))
    }

    @Test fun explicitSavedProtectionChoiceOverridesItsDefault() {
        val preferences = AutomationPreferenceState()
        assertTrue(preferences.read("protectConnectionControls") { true })
        assertFalse(preferences.read("clipboardAccessEnabled") { false })
        var stored = AutomationPreferenceDefaults.value("protectConnectionControls")
        preferences.save("protectConnectionControls", true, { stored }) { stored = it; true }
        assertTrue(AutomationPreferenceState().read("protectConnectionControls") { stored })
    }

    @Test fun settingsRemainIndependentAndSuccessfulSavesCanBeReadByANewInstance() {
        val stored = mutableMapOf("clipboard" to true, "protect" to true)
        val preferences = AutomationPreferenceState()
        preferences.save("clipboard", false, { stored.getValue("clipboard") }) { stored["clipboard"] = it; true }
        assertFalse(preferences.read("clipboard") { stored.getValue("clipboard") })
        assertTrue(preferences.read("protect") { stored.getValue("protect") })
        assertFalse(AutomationPreferenceState().read("clipboard") { stored.getValue("clipboard") })
    }

    @Test fun failedDiskWriteAndFailedRollbackStillKeepThePreviousEffectiveValue() {
        var stored = true
        val preferences = AutomationPreferenceState()
        assertThrows(IllegalStateException::class.java) {
            preferences.save("clipboard", false, { stored }) { value ->
                if (value) throw IllegalStateException("rollback unavailable")
                stored = value
                false
            }
        }
        assertTrue(preferences.read("clipboard") { stored })
        assertTrue(preferences.read("protect") { true })
    }
}

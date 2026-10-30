package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class AccessibilityStatusTest {
    @Test fun permissionSurvivesTheServiceConnectionGap() {
        assertEquals("reconnecting", AccessibilityStatus.state(authorized = true, ready = false))
        assertEquals("ready", AccessibilityStatus.state(authorized = true, ready = true))
        assertEquals("disabled", AccessibilityStatus.state(authorized = false, ready = false))
    }
    @Test fun connectionServiceDeclaresForegroundSupportWithoutNewRuntimePrompts() {
        val android = "http://schemas.android.com/apk/res/android"
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val services = doc.getElementsByTagName("service")
        val service = (0 until services.length).map { services.item(it) as org.w3c.dom.Element }
            .single { it.getAttributeNS(android, "name") == ".PhoneAccessibilityService" }
        assertEquals("specialUse", service.getAttributeNS(android, "foregroundServiceType"))
        val permissions = doc.getElementsByTagName("uses-permission")
        val names = (0 until permissions.length).map { (permissions.item(it) as org.w3c.dom.Element).getAttributeNS(android, "name") }
        assertTrue("android.permission.FOREGROUND_SERVICE" in names)
        assertTrue("android.permission.FOREGROUND_SERVICE_SPECIAL_USE" in names)
    }
}

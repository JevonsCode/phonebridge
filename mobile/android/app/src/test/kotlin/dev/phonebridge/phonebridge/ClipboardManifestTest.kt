package dev.phonebridge.phonebridge

import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class ClipboardManifestTest {
    @Test fun clipboardFocusUsesExistingAccessibilityAuthorizationWithoutAnActivityOrOverlayPermission() {
        val document = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val android = "http://schemas.android.com/apk/res/android"
        val activities = document.getElementsByTagName("activity")
        val activityNames = (0 until activities.length).map {
            (activities.item(it) as org.w3c.dom.Element).getAttributeNS(android, "name")
        }
        assertFalse(activityNames.any { it.endsWith("ClipboardBridgeActivity") })
        val permissions = document.getElementsByTagName("uses-permission")
        val permissionNames = (0 until permissions.length).map {
            (permissions.item(it) as org.w3c.dom.Element).getAttributeNS(android, "name")
        }
        assertFalse(permissionNames.contains("android.permission.SYSTEM_ALERT_WINDOW"))
        assertFalse(permissionNames.contains("android.permission.READ_CLIPBOARD_IN_BACKGROUND"))
    }
}

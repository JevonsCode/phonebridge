package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class FileProviderManifestTest {
    @Test fun eachFileAuthorityHasItsOwnProviderComponent() {
        val document = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val providers = document.getElementsByTagName("provider")
        val android = "http://schemas.android.com/apk/res/android"
        val components = (0 until providers.length).map { providers.item(it) as org.w3c.dom.Element }
            .filter { it.getAttributeNS(android, "authorities").endsWith(".files") || it.getAttributeNS(android, "authorities").endsWith(".updates") }
            .map { it.getAttributeNS(android, "name") }
        assertEquals(2, components.size)
        // Android keys provider instances by ComponentName. Reusing the same class
        // makes the inbox resolve to the updater and reject its content URI.
        assertEquals("Inbox and APK update providers must be distinct components", 2, components.distinct().size)
    }
}

package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class UsbLinkTest {
    private val token = "a".repeat(43)

    @Test fun digestMatchesTheDesktopDefinition() {
        // Same value as bridge/src/usb-link.ts usbTokenDigest('a' * 43).
        assertEquals("7b3c0197e8f675e53e14ac4248bd8fe02a0982ba394c72b3f469da602805c616", UsbLinkPolicy.tokenDigest(token))
        assertTrue(UsbLinkPolicy.validDigest(UsbLinkPolicy.tokenDigest(token)))
        assertFalse(UsbLinkPolicy.validDigest("ABC"))
        assertFalse(UsbLinkPolicy.validDigest(null))
    }

    @Test fun hintsExpireAndOnlyRouteThroughLoopback() {
        var now = 0L
        val hints = UsbLinkHints({ now }, ttlMillis = 1000)
        assertNull(hints.endpointFor(token))
        assertTrue(hints.offer(UsbLinkPolicy.tokenDigest(token), 8767))
        assertEquals("ws://127.0.0.1:8767/device", hints.endpointFor(token))
        assertFalse(hints.offer(UsbLinkPolicy.tokenDigest(token), 8767))
        now = 1001
        assertNull(hints.endpointFor(token))
        hints.offer(UsbLinkPolicy.tokenDigest(token), 9000)
        hints.forget(token)
        assertNull(hints.endpointFor(token))
    }

    @Test fun failedRouteCoolsDownUntilReplugged() {
        var now = 0L
        val hints = UsbLinkHints({ now }, ttlMillis = 90_000, failureCooldownMillis = 300_000)
        val digest = UsbLinkPolicy.tokenDigest(token)
        hints.offer(digest, 8767)
        hints.forget(token)
        now = 30_000
        assertFalse(hints.offer(digest, 8767))
        assertNull(hints.endpointFor(token))
        hints.clear()
        assertTrue(hints.offer(digest, 8767))
        assertEquals("ws://127.0.0.1:8767/device", hints.endpointFor(token))
        hints.forget(token)
        now = 340_000
        assertTrue(hints.offer(digest, 8767))
    }

    @Test fun invalidPortsAndDigestsAreRejected() {
        val hints = UsbLinkHints({ 0L })
        for (port in listOf(-1, 0, 80, 1023, 65536)) {
            assertFalse(UsbLinkPolicy.validPort(port))
            try { hints.offer(UsbLinkPolicy.tokenDigest(token), port); throw AssertionError("accepted $port") }
            catch (_: IllegalArgumentException) { }
        }
        try { hints.offer("not-a-digest", 8767); throw AssertionError("accepted digest") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun linkStateReportsOwnerVisibleConditionsInPriorityOrder() {
        assertEquals("unknown", UsbLinkPolicy.linkState(false, true, true, true, false, false, false))
        assertEquals("paused", UsbLinkPolicy.linkState(true, false, true, true, true, false, false))
        assertEquals("accessibility_disabled", UsbLinkPolicy.linkState(true, true, false, true, false, false, false))
        assertEquals("connected_usb", UsbLinkPolicy.linkState(true, true, true, false, true, true, false))
        assertEquals("connected_wireless", UsbLinkPolicy.linkState(true, true, true, true, true, false, false))
        assertEquals("locked", UsbLinkPolicy.linkState(true, true, true, false, false, false, true))
        assertEquals("connecting", UsbLinkPolicy.linkState(true, true, true, true, false, false, true))
        assertEquals("waiting", UsbLinkPolicy.linkState(true, true, true, true, false, false, false))
    }

    @Test fun manifestProtectsUsbEntriesWithShellOnlyPermission() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val receiver = manifest.substringAfter("android:name=\".UsbLinkReceiver\"").substringBefore("</receiver>")
        assertTrue(receiver.contains("android:permission=\"android.permission.DUMP\""))
        val alias = manifest.substringAfter("android:name=\".UsbPairingActivity\"").substringBefore("</activity-alias>")
        assertTrue(alias.contains("android:permission=\"android.permission.DUMP\""))
        assertTrue(manifest.contains("android.permission.POST_PROMOTED_NOTIFICATIONS"))
    }
}

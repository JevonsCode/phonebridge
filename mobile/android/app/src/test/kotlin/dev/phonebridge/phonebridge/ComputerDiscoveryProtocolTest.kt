package dev.phonebridge.phonebridge

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ComputerDiscoveryProtocolTest {
    private val token = "a".repeat(32)
    private val nonce = "00112233445566778899aabbccddeeff"
    private val record = TrustedPairing("ws://192.168.1.111:8767/device", token, true, listOf("com.example.app"), true, true)
    private fun reply() = JSONObject().put("type", "phonebridge_found").put("version", 1)
        .put("identity", "2b73005894ab0b082c4d5e4c3c1ea783b154e94dcab3d34739c039bd1dee9cdd")
        .put("nonce", nonce).put("endpoint", "ws://192.168.1.159:8767/device")
        .put("proof", "c94775d725763a9532b403de1b1713f2fb9bc6e21c055439bcb6665471c0d146")

    @Test fun sharesDesktopGoldenVectorWithoutSendingToken() {
        val request = ComputerDiscoveryProtocol.request(token, nonce)
        assertFalse(request.contains(token))
        assertEquals(reply().getString("identity"), JSONObject(request).getString("identity"))
        assertEquals("ws://192.168.1.159:8767/device", ComputerDiscoveryProtocol.verify(reply().toString(), record, nonce))
    }
    @Test fun staleUnpairedOrEditedRepliesDoNotRelocateTrust() {
        assertNull(ComputerDiscoveryProtocol.verify(reply().toString(), record, "0".repeat(32)))
        assertNull(ComputerDiscoveryProtocol.verify(reply().toString(), record.copy(token = "b".repeat(32)), nonce))
        assertNull(ComputerDiscoveryProtocol.verify(reply().put("endpoint", "ws://192.168.1.9:8767/device").toString(), record, nonce))
        assertNull(ComputerDiscoveryProtocol.verify("{}", record, nonce))
        assertNull(ComputerDiscoveryProtocol.verify(reply().toString(), record.copy(allowInsecureLocal = false), nonce))
    }
    @Test fun cancellationClosesCurrentAndLaterSockets() {
        val attempt = TrustedComputerDiscovery.Attempt(); var closed = 0
        attempt.onClose { closed++ }; attempt.cancel(); attempt.onClose { closed++ }; attempt.cancel()
        assertFalse(attempt.active); assertEquals(2, closed)
    }
    @Test fun pauseForgetOrReplacedTrustCannotUseAnOldDiscovery() {
        assertTrue(ComputerDiscoveryProtocol.sameResumableTrust(record, record))
        assertFalse(ComputerDiscoveryProtocol.sameResumableTrust(record, null))
        assertFalse(ComputerDiscoveryProtocol.sameResumableTrust(record, record.copy(resumeAllowed = false)))
        assertFalse(ComputerDiscoveryProtocol.sameResumableTrust(record, record.copy(token = "b".repeat(32))))
        assertFalse(ComputerDiscoveryProtocol.sameResumableTrust(record, record.copy(endpoint = "ws://192.168.1.7:8767/device")))
    }
}

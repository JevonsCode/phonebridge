package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EndpointPolicyTest {
    @Test fun tokenMatchesHubBase64urlAlphabetAndLength() {
        EndpointPolicy.validateToken("Ab_9-".repeat(7))
        EndpointPolicy.validateToken("a".repeat(256))
        listOf("a".repeat(31), "a".repeat(257), "a".repeat(31) + " ",
            "a".repeat(31) + "+", "a".repeat(31) + "/", "a".repeat(31) + "=",
            "a".repeat(31) + "中").forEach {
            try {
                EndpointPolicy.validateToken(it)
                throw AssertionError("Expected token rejection")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun permitsOnlyAcknowledgedPrivateCleartext() {
        listOf("10.0.0.8", "127.0.0.1", "172.16.0.1", "172.31.255.255",
            "192.168.1.2", "100.64.0.1", "100.127.255.255", "[::1]").forEach {
            assertTrue(EndpointPolicy.isPrivateLiteral(it))
            assertEquals("ws://$it:8765/device", EndpointPolicy.validate("ws://$it:8765", true))
            rejected("ws://$it:8765", false)
        }
    }

    @Test fun refusesHostnamesPublicAndAmbiguousIpSpellings() {
        listOf("localhost", "example.com", "8.8.8.8", "0.0.0.0", "169.254.1.1",
            "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1",
            "127.1", "2130706433", "0177.0.0.1", "127.0.0.999",
            "[::ffff:127.0.0.1]").forEach {
            assertFalse(EndpointPolicy.isPrivateLiteral(it))
            rejected("ws://$it:8765", true)
        }
    }

    @Test fun validatesSecureEndpointStructure() {
        assertEquals("wss://bridge.example/device", EndpointPolicy.validate("wss://bridge.example", false))
        listOf("https://bridge.example", "wss://user:secret@bridge.example",
            "wss://bridge.example/device?token=secret", "wss://bridge.example/device#fragment",
            "wss://bridge.example/other", "wss://bridge.example:0", "wss://bridge.example:65536",
            "wss://", "ws://127.0.0.1/%64evice").forEach { rejected(it, true) }
    }

    private fun rejected(endpoint: String, allow: Boolean) {
        try {
            EndpointPolicy.validate(endpoint, allow)
            throw AssertionError("Expected endpoint rejection")
        } catch (_: IllegalArgumentException) { }
    }
}

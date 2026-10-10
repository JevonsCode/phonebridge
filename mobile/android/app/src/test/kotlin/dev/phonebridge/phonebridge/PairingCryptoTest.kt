package dev.phonebridge.phonebridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import javax.crypto.KeyGenerator

class PairingCryptoTest {
    private fun key() = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test fun credentialsRoundTripAsAuthenticatedCiphertext() {
        val secret = "test-token-and-owner-action-consent".toByteArray()
        val key = key()
        val record = PairingCrypto.encrypt(secret, key)
        assertFalse(String(record, Charsets.ISO_8859_1).contains("test-token"))
        assertArrayEquals(secret, PairingCrypto.decrypt(record, key))
    }

    @Test fun everySaveUsesFreshRandomNonce() {
        val key = key()
        val secret = "same trusted pairing".toByteArray()
        assertFalse(PairingCrypto.encrypt(secret, key).contentEquals(PairingCrypto.encrypt(secret, key)))
    }

    @Test fun ciphertextTamperingAndWrongKeysAreRejected() {
        val key = key()
        val record = PairingCrypto.encrypt("trusted".toByteArray(), key)
        val altered = record.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        rejected { PairingCrypto.decrypt(altered, key) }
        rejected { PairingCrypto.decrypt(record, key()) }
    }

    @Test fun truncatedOversizedAndUnknownVersionsAreRejected() {
        val key = key()
        rejected { PairingCrypto.decrypt(byteArrayOf(1), key) }
        rejected { PairingCrypto.decrypt(ByteArray(PairingCrypto.MAX_RECORD_BYTES + 1), key) }
        val record = PairingCrypto.encrypt("trusted".toByteArray(), key).apply { this[0] = 2 }
        rejected { PairingCrypto.decrypt(record, key) }
        rejected { PairingCrypto.encrypt(ByteArray(PairingCrypto.MAX_PLAIN_BYTES + 1), key) }
    }

    @Test fun fullComputerCatalogRoundTripsThroughActualAuthenticatedEnvelope() {
        val packages = (0 until 64).map { val prefix = "dev.example.p$it."; prefix + "a".repeat(255 - prefix.length) }
        var computers = TrustedComputers()
        repeat(16) { index ->
            val endpoint = EndpointPolicy.validate("wss://computer$index.example/device", false)
            val token = "test-$index-" + "a".repeat(32)
            EndpointPolicy.validateToken(token)
            computers = computers.remember(TrustedPairing(endpoint, token, false, packages, index % 2 == 0, true))
        }
        val plain = computers.encode().toByteArray(Charsets.UTF_8)
        org.junit.Assert.assertTrue(plain.size > 32768)
        val key = key()
        val restored = TrustedComputers.decode(String(PairingCrypto.decrypt(PairingCrypto.encrypt(plain, key), key), Charsets.UTF_8))
        org.junit.Assert.assertEquals(computers, restored)
    }

    private fun rejected(action: () -> Unit) {
        try { action(); throw AssertionError("Expected authenticated-record rejection") }
        catch (_: IllegalArgumentException) { }
        catch (_: javax.crypto.AEADBadTagException) { }
    }
}

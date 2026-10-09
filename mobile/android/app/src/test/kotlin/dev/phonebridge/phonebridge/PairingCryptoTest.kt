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
        rejected { PairingCrypto.decrypt(ByteArray(32801), key) }
        val record = PairingCrypto.encrypt("trusted".toByteArray(), key).apply { this[0] = 2 }
        rejected { PairingCrypto.decrypt(record, key) }
        rejected { PairingCrypto.encrypt(ByteArray(32769), key) }
    }

    private fun rejected(action: () -> Unit) {
        try { action(); throw AssertionError("Expected authenticated-record rejection") }
        catch (_: IllegalArgumentException) { }
        catch (_: javax.crypto.AEADBadTagException) { }
    }
}
